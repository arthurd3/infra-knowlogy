#!/usr/bin/env python3
"""Mede as armadilhas de shell que este repositório pisou, e grava
site/src/data/bash-measured.json.

Mesmo papel do sizes.sh e do tracing-measure.py: a lição cita este arquivo e
nenhum número dela é escrito à mão.

Não precisa de Docker nem da stack — só de bash. É de propósito: uma lição
sobre escrever script não deveria depender da infraestrutura que o script
gerencia.

O que mede, e por que cada coisa:

  sigpipe      `texto | grep -q PADRÃO` com `pipefail` INVERTE o resultado
               quando o padrão aparece cedo. É a armadilha 29, e a medição
               mostra o que a descrição dela não dizia: não é um limiar de
               tamanho, é uma CORRIDA — falha metade das vezes com 1 KiB e
               sempre acima do buffer do pipe.
  local        `local v=$(cmd)` engole o código de saída de `cmd`. Com
               `set -e`, a forma "mais arrumada" é a que NÃO detecta o erro.
  aspas        variável não citada vira N argumentos.
  classes      `\\s` × `[[:space:]]`: a armadilha 27 afirmava que a primeira
               reprova arquivos pinados. Não reproduz, e esta medição é a
               prova — o conselho continua bom por portabilidade, não por
               comportamento.
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "site/src/data/bash-measured.json"
RODADAS = 40


def bash(script):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, cwd=ROOT)


def sigpipe(bytes_depois, rodadas=RODADAS):
    """Quantas vezes, em `rodadas`, o `grep -q` diz "não achei" achando.

    O escritor emite o padrão na PRIMEIRA linha e depois `bytes_depois` bytes
    de enchimento. O `grep -q` sai no primeiro acerto e fecha o pipe; o
    escritor, que ainda tem coisa para escrever, morre de SIGPIPE (141) e o
    `pipefail` propaga esse não-zero. Achar vira "não achei".
    """
    r = bash(f'''
    testa() {{
      ( set -o pipefail
        {{ printf 'ACHOU\\n'; head -c {bytes_depois} /dev/zero | tr '\\0' 'x'; }} | grep -q ACHOU
      ) 2>/dev/null
    }}
    F=0; for _ in $(seq 1 {rodadas}); do testa || F=$((F+1)); done; echo "$F"
    ''')
    return int(r.stdout.strip() or -1)


def sem_pipe(bytes_depois, rodadas=RODADAS):
    """A mesma pergunta pela forma correta: `case` sobre a saída já capturada."""
    r = bash(f'''
    testa() {{
      ( set -o pipefail
        T=$( {{ printf 'ACHOU\\n'; head -c {bytes_depois} /dev/zero | tr '\\0' 'x'; }} )
        case "$T" in *ACHOU*) return 0 ;; *) return 1 ;; esac
      ) 2>/dev/null
    }}
    F=0; for _ in $(seq 1 {rodadas}); do testa || F=$((F+1)); done; echo "$F"
    ''')
    return int(r.stdout.strip() or -1)


def main():
    buf = int(bash(
        "python3 -c 'import fcntl,os; r,w=os.pipe(); print(fcntl.fcntl(w,1032))'"
    ).stdout.strip() or 0)

    tamanhos = [1024, 16384, 65536, 131072, 1048576]
    print(f"medindo a corrida do SIGPIPE ({RODADAS} rodadas por tamanho)…", file=sys.stderr)
    corrida = [
        {"bytes": n, "falhas_com_pipe": sigpipe(n), "falhas_sem_pipe": sem_pipe(n),
         "rodadas": RODADAS}
        for n in tamanhos
    ]

    # `local v=$(cmd)`: o `local` é um comando, e o código de saída que sobra é
    # o DELE. A forma separada preserva o do subcomando.
    r = bash('f(){ local v=$(exit 7); echo $?; }; f')
    local_junto = int(r.stdout.strip() or -1)
    r = bash('f(){ local v; v=$(exit 7); echo $?; }; f')
    local_separado = int(r.stdout.strip() or -1)

    # Com set -e a diferença deixa de ser cosmética.
    sobreviveu = bash('set -e; f(){ local v=$(exit 7); }; f; echo vivo').stdout.strip() == "vivo"
    morreu = bash('set -e; f(){ local v; v=$(exit 7); }; f; echo vivo').returncode != 0

    # Aspas: uma palavra vira N.
    r = bash('c(){ echo $#; }; V="a b c"; c $V')
    sem_aspas = int(r.stdout.strip() or -1)
    r = bash('c(){ echo $#; }; V="a b c"; c "$V"')
    com_aspas = int(r.stdout.strip() or -1)

    # `\s` × `[[:space:]]` contra um Dockerfile REAL deste repositório.
    alvo = "stack/services/api-go/Dockerfile"
    classes = {}
    for nome, cmd in [
        ("grep_ere", "/usr/bin/grep -cE '^FROM{p}' " + alvo),
        ("awk", "awk '/^FROM{p}/{{n++}} END{{print n+0}}' " + alvo),
        ("sed", "sed -nE '/^FROM{p}/p' " + alvo + " | wc -l"),
    ]:
        classes[nome] = {
            "barra_s": int(bash(cmd.format(p=r"\s+")).stdout.strip() or -1),
            "posix": int(bash(cmd.format(p="[[:space:]]+")).stdout.strip() or -1),
        }
    # E a afirmação que a armadilha fazia: `\s` casaria a letra "s"?
    casa_letra_s = int(bash(
        "printf 'FROMsssalpine\\n' | /usr/bin/grep -cE '^FROM\\s+' || true"
    ).stdout.strip() or 0)

    dados = {
        "_comentario": "Gerado por tools/scripts/bash-traps-measure.py — não edite à mão.",
        "medido_em": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "bash": bash("echo $BASH_VERSION").stdout.strip(),
        "grep": bash("/usr/bin/grep --version | head -1").stdout.strip(),
        "buffer_de_pipe_bytes": buf,
        "corrida_sigpipe": corrida,
        "codigo_de_saida": {
            "local_na_mesma_linha": local_junto,
            "local_separado": local_separado,
            "set_e_sobrevive_com_local_junto": sobreviveu,
            "set_e_morre_com_local_separado": morreu,
        },
        "aspas": {"sem_aspas_argumentos": sem_aspas, "com_aspas_argumentos": com_aspas},
        "classes_de_caractere": {
            "alvo": alvo,
            "por_ferramenta": classes,
            "barra_s_casa_letra_s": casa_letra_s,
        },
    }
    OUT.write_text(json.dumps(dados, indent=2, ensure_ascii=False) + "\n")
    print(f"gravado: {OUT.relative_to(ROOT)}", file=sys.stderr)
    for c in corrida:
        print(f"  {c['bytes']:>8} bytes  com pipe: {c['falhas_com_pipe']:>2}/{RODADAS} falhas"
              f"   sem pipe: {c['falhas_sem_pipe']:>2}/{RODADAS}")
    print(f"  local junto: $?={local_junto}   local separado: $?={local_separado}")


if __name__ == "__main__":
    main()
