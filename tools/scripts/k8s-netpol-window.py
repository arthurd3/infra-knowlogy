#!/usr/bin/env python3
"""Mede a janela em que um pod recém-criado ainda NÃO está sob NetworkPolicy.

Roda DENTRO do cluster, num pod descartável, e é a única forma honesta de
medir isto: o instante zero tem que ser o do próprio pod, e nenhum relógio de
fora do cluster sabe quando o primeiro pacote ficou possível.

O que se espera ver, e por quê: a `default-deny` seleciona TODOS os pods do
namespace com `policyTypes: [Ingress, Egress]`, então este pod não deveria
alcançar 1.1.1.1 em momento nenhum. Mas as regras de dataplane são programadas
DEPOIS de o container começar a rodar — o agente de rede reage a um evento que
já aconteceu. O resultado é uma janela curta de egresso irrestrito.

Duas conclusões saem daqui, e são independentes:

  · `houveJanela` — se der `true`, NetworkPolicy não é defesa contra um
    processo malicioso que exfiltra no primeiro instante. Defesa em
    profundidade (o guard de SSRF da aplicação, segredo que não está na
    imagem) não é redundância: é a única coisa que cobre este intervalo.

  · `fechou` — se der `false`, a policy simplesmente NÃO está valendo, o que é
    outro problema inteiro (kind < 0.23 aceita a API e não aplica nada).
"""
import json, socket, time

ALVO = ("1.1.1.1", 443)
LIMITE_S = 25.0
INTERVALO_S = 0.05


def alcanca():
    try:
        socket.create_connection(ALVO, 1).close()
        return True
    except Exception:
        return False


t0 = time.monotonic()
ultima_ok = None
primeira_recusa = None

while time.monotonic() - t0 < LIMITE_S:
    agora = time.monotonic() - t0
    if alcanca():
        ultima_ok = agora
        # Uma recusa seguida de sucesso é ruído de rede, não a policy: zera.
        primeira_recusa = None
    else:
        if primeira_recusa is None:
            primeira_recusa = agora
        # Duas recusas consecutivas após ter havido sucesso — ou já no
        # começo — bastam para chamar de fechado.
        elif agora - primeira_recusa > 1.0:
            break
    time.sleep(INTERVALO_S)

print(json.dumps({
    "houveJanela": ultima_ok is not None,
    "fechou": primeira_recusa is not None,
    "ultimaConexaoPermitidaMs": round(ultima_ok * 1000) if ultima_ok is not None else None,
    "primeiraRecusaMs": round(primeira_recusa * 1000) if primeira_recusa is not None else None,
    # A janela é o ponto médio entre o último sucesso e a primeira recusa: é o
    # melhor que uma amostragem de 50 ms permite afirmar.
    "janelaMs": (round((ultima_ok + primeira_recusa) * 500)
                 if ultima_ok is not None and primeira_recusa is not None else 0),
}))
