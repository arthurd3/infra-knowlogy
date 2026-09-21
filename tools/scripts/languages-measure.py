#!/usr/bin/env python3
"""Compara as três linguagens de produção desta stack e grava
site/src/data/languages-measured.json.

Go na api, Python no worker, Node/Astro no site. A escolha foi deliberada
(ADR 0005) e o valor didático é justamente poder comparar as três fazendo parte
do MESMO sistema, no mesmo host, no mesmo dia.

O que mede, e por que cada coisa:

  repouso      memória residente de cada processo sem carga. É o número que
               decide quantas réplicas cabem num nó, e o que separa um runtime
               compilado de um interpretado.
  lock         linhas e bytes do arquivo de lock. Não é vaidade: cada linha é
               uma decisão que alguém terá de auditar quando um CVE sair.
  erro         QUANDO o typo aparece. O mesmo erro, no mesmo ramo morto,
               impede o build em Go e passa despercebido em Python. É a
               diferença que se paga às 3 da manhã.

Precisa da stack no ar para o repouso (`make up`). Sem ela, grava o resto e
marca `repouso_medido: false` — meia medição declarada é honesta; meia medição
silenciosa não é.
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "site/src/data/languages-measured.json"
DEMO = ROOT / "tools/scripts/fixtures/typo-no-ramo-morto"


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, **kw)


def linhas_e_bytes(rel):
    p = ROOT / rel
    if not p.exists():
        return None
    return {"arquivo": rel, "linhas": p.read_text(errors="ignore").count("\n"),
            "bytes": p.stat().st_size}


def repouso():
    """Memória residente de cada container, sem carga."""
    r = sh(["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.MemUsage}}"])
    if r.returncode != 0:
        return None
    saida = {}
    for linha in r.stdout.splitlines():
        if "\t" not in linha:
            continue
        nome, uso = linha.split("\t", 1)
        for chave, marca in (("api_go", "-api-"), ("worker_py", "-worker-"), ("web_node", "-web-")):
            if marca in nome:
                # "9.449MiB / 256MiB" -> 9.449
                bruto = uso.split("/")[0].strip()
                num = "".join(c for c in bruto if c.isdigit() or c == ".")
                saida[chave] = {"mib": float(num or 0), "container": nome}
    return saida or None


def quando_o_erro_aparece():
    """O MESMO typo, no MESMO ramo morto, nas duas linguagens.

    Go recusa o build e não produz binário; Python sobe, atende e sai com 0 —
    o defeito fica esperando o dia em que aquele ramo executar.

    A fixture é versionada (tools/scripts/fixtures/) para que o leitor possa
    rodar o mesmo teste, e para que a afirmação da lição não dependa de um
    arquivo que só existiu na minha máquina.
    """
    digest = None
    df = (ROOT / "stack/services/api-go/Dockerfile").read_text()
    for linha in df.splitlines():
        if linha.startswith("FROM golang:"):
            digest = linha.split()[1]
            break
    if digest is None or not DEMO.exists():
        return None

    go = sh(["docker", "run", "--rm", "-v", f"{DEMO}/go:/src:ro,z", "-w", "/src",
             digest, "sh", "-c", "go build -o /tmp/bin ./main.go"])
    py = sh(["docker", "run", "--rm", "-v", f"{DEMO}/py:/src:ro,z", "-w", "/src",
             "python:3.13-alpine", "python", "main.py"])
    return {
        "go": {"saida": go.returncode, "produziu_binario": go.returncode == 0,
               "mensagem": (go.stderr or go.stdout).strip().splitlines()[-1][:120] if (go.stderr or go.stdout) else ""},
        "python": {"saida": py.returncode, "rodou_ate_o_fim": "atendendo" in py.stdout,
                   "mensagem": py.stdout.strip().replace("\n", " · ")[:120]},
    }


def main():
    print("medindo as três linguagens…", file=sys.stderr)

    locks = [linhas_e_bytes(f) for f in (
        "stack/services/api-go/go.sum",
        "stack/services/worker-py/uv.lock",
        "site/package-lock.json",
    )]
    locks = [x for x in locks if x]

    codigo = {}
    for chave, padrao in (("api_go", "stack/services/api-go/*.go"),
                          ("worker_py", "stack/services/worker-py/worker/*.py")):
        arquivos = sorted(ROOT.glob(padrao))
        codigo[chave] = {
            "arquivos": len(arquivos),
            "linhas": sum(f.read_text(errors="ignore").count("\n") for f in arquivos),
        }

    em_repouso = repouso()
    erro = quando_o_erro_aparece()

    dados = {
        "_comentario": "Gerado por tools/scripts/languages-measure.py — não edite à mão.",
        "medido_em": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "repouso_medido": em_repouso is not None,
        "repouso": em_repouso or {},
        "locks": locks,
        "codigo": codigo,
        "quando_o_erro_aparece": erro or {},
    }
    OUT.write_text(json.dumps(dados, indent=2, ensure_ascii=False) + "\n")
    print(f"gravado: {OUT.relative_to(ROOT)}", file=sys.stderr)
    if em_repouso:
        for k, v in em_repouso.items():
            print(f"  {k:<10} {v['mib']:>7.2f} MiB em repouso")
    for l in locks:
        print(f"  {l['arquivo'].split('/')[-1]:<20} {l['linhas']:>5} linhas  {l['bytes']:>8} bytes")
    if erro:
        print(f"  go: saída {erro['go']['saida']} (binário: {erro['go']['produziu_binario']})"
              f" · python: saída {erro['python']['saida']} (rodou até o fim: {erro['python']['rodou_ate_o_fim']})")


if __name__ == "__main__":
    main()
