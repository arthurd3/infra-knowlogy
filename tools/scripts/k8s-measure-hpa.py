#!/usr/bin/env python3
"""Mede quanto tempo o HPA leva para reagir a uma carga real.

O número que interessa não é "o HPA escala" — isso o `get hpa` já diz. É
QUANTO TEMPO passa entre a carga chegar e existir um pod novo pronto, porque é
esse intervalo que decide se o HPA salva você de um pico de tráfego ou não.

O intervalo tem três somas, e o script separa as três:

  1. o metrics-server raspar o kubelet          (--metric-resolution, 15 s)
  2. o HPA ler a métrica e decidir              (--horizontal-pod-autoscaler-sync-period, 15 s)
  3. o pod novo ser agendado, puxado e ficar Ready

As duas primeiras são LATÊNCIA DE PERCEPÇÃO e não dependem da sua aplicação:
mesmo com um pod que sobe instantaneamente, o HPA ainda passa esse tempo cego.

Saída: JSON em site/src/data/k8s-hpa.json.
"""
import json, os, pathlib, subprocess, sys, threading, time, urllib.request

NS = "infra-knowlogy"
ALVO = os.environ.get("K8S_URL", "http://127.0.0.1:8081") + "/api/links"
SEGUNDOS_DE_CARGA = int(os.environ.get("HPA_CARGA_S", "75"))
THREADS = int(os.environ.get("HPA_THREADS", "24"))
# Três por padrão, e não uma. Medido aqui: a janela cega deu 6,4 s, 23,4 s e
# 36,2 s em execuções seguidas do MESMO cluster com a MESMA carga. Não é
# ruído — é a fase em que a carga cai dentro de dois laços independentes de
# 15 s (a raspagem do metrics-server e a sincronização do HPA). Uma execução
# só produziria um número que a próxima desmente, e a lição citaria esse
# número como se fosse uma constante.
REPETICOES = int(os.environ.get("HPA_REPETICOES", "3"))


def kubectl(*args):
    return subprocess.run(["kubectl", "-n", NS, *args],
                          capture_output=True, text=True).stdout.strip()


def replicas():
    v = kubectl("get", "deploy", "api", "-o", "jsonpath={.status.replicas}")
    return int(v) if v.isdigit() else 0


def prontos():
    v = kubectl("get", "deploy", "api", "-o", "jsonpath={.status.readyReplicas}")
    return int(v) if v.isdigit() else 0


def utilizacao():
    v = kubectl("get", "hpa", "api", "-o",
                "jsonpath={.status.currentMetrics[0].resource.current.averageUtilization}")
    return int(v) if v.isdigit() else None


def pods_prontos():
    """Nomes dos pods da api que estão Ready — não a CONTAGEM.

    A primeira versão deste script comparava contagens e mediu 18,8 s para as
    três etapas, que é obviamente errado. A causa: o HPA ainda carregava
    `desiredReplicas: 4` da rodada anterior (a estabilização de descida segura
    o valor por 5 minutos), então os pods "novos" já existiam antes da carga.
    Rastrear NOME resolve — pod novo é pod que não estava na lista inicial.
    """
    linhas = kubectl("get", "pods", "-l", "app=api",
                     "-o", "jsonpath={range .items[*]}{.metadata.name} "
                           "{.status.conditions[?(@.type=='Ready')].status}{'\\n'}{end}")
    return {l.split()[0] for l in linhas.splitlines()
            if len(l.split()) == 2 and l.split()[1] == "True"}


def boot_do_pod(nome):
    """Quanto o pod levou de criado a Ready, pelos carimbos DELE.

    A primeira versão media isto por diferença de dois instantes do laço de
    polling e cravou 0,0 s — errado. A causa é que `.status.replicas` do
    Deployment é escrito pelo controlador de forma assíncrona e ATRASA em
    relação à criação do pod: quando o campo diz 4, o pod pode já estar Ready
    há um segundo. O relógio de fora não serve; os carimbos do objeto servem.
    """
    criado = kubectl("get", "pod", nome, "-o",
                     "jsonpath={.metadata.creationTimestamp}")
    ready = kubectl("get", "pod", nome, "-o",
                    "jsonpath={.status.conditions[?(@.type=='Ready')].lastTransitionTime}")
    try:
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        t_c = time.mktime(time.strptime(criado, fmt))
        t_r = time.mktime(time.strptime(ready.split()[0], fmt))
        return round(t_r - t_c, 1)
    except Exception:
        return None


def zerar():
    """Devolve o mundo ao estado base — e espera de verdade.

    Apagar o HPA é obrigatório: com ele de pé, um `scale --replicas=2` é
    desfeito no próximo ciclo de 15 s, porque a estabilização de descida ainda
    segura o desejo anterior. Quem reduz é o HPA, no tempo dele.
    """
    subprocess.run(["kubectl", "-n", NS, "delete", "hpa", "api", "--ignore-not-found"],
                   capture_output=True)
    subprocess.run(["kubectl", "-n", NS, "scale", "deploy/api", "--replicas=2"],
                   capture_output=True)
    for _ in range(60):
        if replicas() == 2 and len(pods_prontos()) == 2:
            break
        time.sleep(2)
    subprocess.run(["kubectl", "-n", NS, "apply", "-f", "k8s/base/hpa/api.yaml"],
                   capture_output=True, cwd=pathlib.Path(__file__).resolve().parents[2])
    # E espera o HPA ter MÉTRICA, não só existir: recém-criado ele reporta
    # `<unknown>` por uma ou duas janelas, e medir a partir daí somaria ao
    # resultado um atraso que é do teste, não do HPA.
    for _ in range(40):
        if utilizacao() is not None:
            break
        time.sleep(3)

    # E espera a CPU ESFRIAR — não basta ter métrica, a métrica precisa ser
    # de um sistema em repouso. Sem isto, as rodadas 2 e 3 começavam com
    # 136% e 96% de utilização herdados da carga anterior, e o "t=0" deixava
    # de ser o instante em que a carga chegou: o HPA já tinha visto CPU alta
    # antes de o teste começar. Foi o que produziu uma medição de 53 s, acima
    # do limite teórico de 30 s — número impossível que só existia porque a
    # linha de base estava quente.
    ALVO_FRIO = 30
    for _ in range(60):
        u = utilizacao()
        if u is not None and u < ALVO_FRIO:
            return
        time.sleep(3)


def uma_rodada(n):
    print(f"   rodada {n}/{REPETICOES}: zerando…", file=sys.stderr)
    zerar()
    base_rep = replicas()
    antigos = pods_prontos()
    print(f"   base: {base_rep} réplicas · utilização {utilizacao()}%", file=sys.stderr)

    parar = threading.Event()

    def bate():
        while not parar.is_set():
            try:
                urllib.request.urlopen(ALVO, timeout=3).read()
            except Exception:
                pass

    ts = [threading.Thread(target=bate, daemon=True) for _ in range(THREADS)]
    t0 = time.monotonic()
    for t in ts:
        t.start()

    percebeu = escalou = pronto = boot = None
    alvo_rep = None
    while time.monotonic() - t0 < SEGUNDOS_DE_CARGA:
        agora = time.monotonic() - t0
        u = utilizacao()
        if percebeu is None and u is not None and u > 60:
            percebeu = agora
            print(f"   t={agora:5.1f}s  HPA percebeu: {u}% > 60%", file=sys.stderr)
        r = replicas()
        if escalou is None and r > base_rep:
            escalou, alvo_rep = agora, r
            print(f"   t={agora:5.1f}s  escalou: {base_rep} -> {r}", file=sys.stderr)
        novos = pods_prontos() - antigos
        if escalou is not None and pronto is None and novos:
            pronto = agora
            nome = sorted(novos)[0]
            boot = boot_do_pod(nome)
            print(f"   t={agora:5.1f}s  pod NOVO pronto: {nome} "
                  f"(boot próprio: {boot}s)", file=sys.stderr)
            break
        time.sleep(2)

    parar.set()
    for t in ts:
        t.join(timeout=5)

    return {
        "rodada": n,
        "replicasAntes": base_rep,
        "replicasDepois": alvo_rep,
        # As três somas, separadas.
        "segundosAtePerceber": round(percebeu, 1) if percebeu else None,
        "segundosAteEscalar": round(escalou, 1) if escalou else None,
        # Nota de resolução: os carimbos do Kubernetes são RFC3339 com
        # granularidade de UM SEGUNDO. A api sobe abaixo disso (binário Go,
        # distroless, imagem já no nó), então este campo vale 0 ou 1 conforme
        # a criação e o Ready caiam no mesmo segundo ou não. Não é ruído a
        # corrigir: é o piso do que o próprio Kubernetes consegue reportar, e
        # está bem longe de importar diante de uma janela cega de dezenas de
        # segundos.
        "resolucaoDosCarimbosSegundos": 1,
        "segundosAtePodPronto": round(pronto, 1) if pronto else None,
        # A janela cega: o tempo em que a carga já está apertando e o HPA ainda
        # não fez nada. É o número honesto para responder "o HPA me salva de um
        # pico?" — se o pico for mais curto que isto, não salva.
        # O tempo de subir o pod, isolado da percepção. É a única parcela que a
        # sua aplicação controla — as outras duas são do Kubernetes.
        "segundosDeBootDoPod": boot,
        # A janela cega: a carga já aperta e o HPA ainda não fez nada. É o
        # número honesto para "o HPA me salva de um pico?" — pico mais curto
        # que isto, não salva.
        "janelaCegaSegundos": round(escalou, 1) if escalou else None,
    }


def main():
    rodadas = [uma_rodada(n + 1) for n in range(REPETICOES)]
    cegas = [r["janelaCegaSegundos"] for r in rodadas if r["janelaCegaSegundos"] is not None]
    boots = [r["segundosDeBootDoPod"] for r in rodadas if r["segundosDeBootDoPod"] is not None]

    saida = {
        "_comentario": ("Medido por tools/scripts/k8s-measure-hpa.py contra o cluster kind. "
                        "Carga real pelo edge; os tempos são do instante em que a carga começou."),
        "threadsDeCarga": THREADS,
        "repeticoes": REPETICOES,
        "rodadas": rodadas,
        # A janela cega é uma FAIXA, e a faixa é o ensinamento. O mínimo
        # acontece quando a carga chega logo antes de uma raspagem; o máximo,
        # logo depois de uma.
        "janelaCegaMinSegundos": min(cegas) if cegas else None,
        "janelaCegaMaxSegundos": max(cegas) if cegas else None,
        # O limite que a configuração PREVÊ, para conferir com o medido.
        #
        # A primeira versão deste campo dizia 30 s — 15 de raspagem mais 15 de
        # sincronização — e o portão reprovou com uma medição de 44,7 s. O
        # limite é que estava errado, e o termo que faltava é o mais sutil dos
        # três: **uso de CPU é uma TAXA**, e taxa não sai de uma amostra. O
        # metrics-server calcula o valor pela diferença entre as DUAS últimas
        # raspagens, então uma mudança degrau só está inteiramente refletida
        # depois de duas janelas.
        #
        #   2 × --metric-resolution ............ 30 s  (a taxa precisa de 2 amostras)
        #   1 × sync-period do HPA ............. 15 s  (padrão do controller-manager)
        #                                      ───────
        #                                        45 s
        #
        # Medido aqui: 44,7 s de pior caso. A conta fecha.
        "limiteTeoricoSegundos": 45,
        "limiteTeoricoTermos": {
            "raspagensParaFormarTaxa": 2,
            "metricResolutionSegundos": 15,
            "hpaSyncPeriodSegundos": 15,
        },
        "bootMaxSegundos": max(boots) if boots else None,
        "resolucaoDosCarimbosSegundos": 1,
        "estabilizacaoParaDescerSegundos": 300,
    }
    destino = pathlib.Path(__file__).resolve().parents[2] / "site/src/data/k8s-hpa.json"
    destino.write_text(json.dumps(saida, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(saida, ensure_ascii=False))
    return 0 if cegas else 1


if __name__ == "__main__":
    sys.exit(main())
