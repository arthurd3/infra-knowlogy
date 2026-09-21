#!/usr/bin/env python3
"""Mede o tracing ponta a ponta e grava site/src/data/tracing-measured.json.

Mesmo papel do obs-measure.py e do sizes.sh: a lição de tracing cita este
arquivo e nenhum número dela é escrito à mão.

Precisa do profile `obs` no ar (`make obs`). Sem ele, sai com 2 e não grava —
arquivo de medição meio-preenchido é pior que arquivo ausente, porque parece
atual.

O que mede, e por que cada coisa:

  caminho_feliz     o trace que atravessa edge → api → fila → worker. É a
                    afirmação central da lição: um trace_id, três serviços.
  caminho_retentativa  o MESMO trace quando o enriquecimento falha. Antes do
                    `empacotar()` no reenfileiramento, as tentativas viravam
                    traces órfãos — o caminho que você investiga de madrugada
                    era justamente o que o tracing não cobria.
  custo             o preço da instrumentação em bytes, medido nos dois
                    sentidos: símbolos no binário Go e bytes de pacote no
                    Python. Uma trilha inteira deste repositório é sobre imagem
                    mínima; esconder o custo aqui seria incoerente.
"""
import json
import subprocess
import sys
import collections
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "site/src/data/tracing-measured.json"
EDGE = "http://127.0.0.1:8080"
VOLUME = "infra-knowlogy_otel_traces"
COMPOSE = ["docker", "compose",
           "-f", str(ROOT / "stack/compose.yaml"),
           "-f", str(ROOT / "stack/compose.prod.yaml"),
           "-f", str(ROOT / "stack/compose.obs.yaml"),
           "--profile", "obs"]


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def alpine(*cmd):
    """Roda um comando efêmero com o volume de traces montado."""
    return sh(["docker", "run", "--rm", "-v", f"{VOLUME}:/traces", "alpine:3", *cmd])


def marcar():
    """Marca onde o arquivo de traces está AGORA, em bytes.

    ─── Por que não truncar ────────────────────────────────────────────────
    A primeira versão parava o coletor, truncava o arquivo e o subia de novo.
    Funcionava na bancada e reprovava dentro do `make verify`, sempre no mesmo
    lugar: o span do EDGE sumia do primeiro trace.

    A causa é uma assimetria entre os dois exportadores. O da api e o do worker
    falam OTLP/gRPC, que enfileira e reenvia quando o destino recusa conexão. O
    do Caddy fala OTLP/HTTP e **descarta o lote**. Com o coletor recém-reiniciado
    e um pedido chegando logo em seguida, só o edge perdia spans — e a checagem
    culpava a configuração do edge, que estava certa.

    Marcar o deslocamento não mexe em processo nenhum: o coletor nunca para, não
    há janela em que uma exportação possa cair, e a leitura ignora o que já
    estava lá. Não reiniciar é mais barato E mais correto.
    """
    r = alpine("sh", "-c", "wc -c < /traces/traces.json 2>/dev/null || echo 0")
    try:
        return int(r.stdout.strip() or 0)
    except ValueError:
        return 0


def esperar(cond, limite, oquefalhou):
    import time
    for _ in range(limite):
        if cond():
            return
        time.sleep(1)
    raise SystemExit(f"tracing-measure: {oquefalhou}")


def criar(url):
    r = sh(["curl", "-fsS", "--max-time", "10", "-X", "POST", f"{EDGE}/api/links",
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"url": url})])
    if r.returncode != 0:
        raise SystemExit(f"tracing-measure: a stack não respondeu em {EDGE} — rode `make obs` antes.")
    return json.loads(r.stdout)["code"]


def ler_spans(desde=0):
    # `tail -c +N` é 1-indexado: +1 devolve o arquivo inteiro.
    bruto = alpine("sh", "-c", f"tail -c +{desde + 1} /traces/traces.json 2>/dev/null").stdout
    spans = []
    for linha in bruto.splitlines():
        linha = linha.strip()
        if not linha:
            continue
        try:
            doc = json.loads(linha)
        except json.JSONDecodeError:
            continue
        for rs in doc.get("resourceSpans", []):
            serv = next((a["value"]["stringValue"] for a in rs["resource"]["attributes"]
                         if a["key"] == "service.name"), "?")
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    spans.append(dict(
                        servico=serv, nome=sp["name"], trace=sp["traceId"], span=sp["spanId"],
                        pai=sp.get("parentSpanId", ""),
                        ini=int(sp["startTimeUnixNano"]), fim=int(sp["endTimeUnixNano"])))
    return spans


def resumir(spans):
    """Agrupa por trace e devolve a árvore de cada um, do maior para o menor."""
    por = collections.defaultdict(list)
    for s in spans:
        por[s["trace"]].append(s)
    saida = []
    for tid, ss in sorted(por.items(), key=lambda kv: -len(kv[1])):
        porsid = {s["span"]: s for s in ss}
        t0 = min(s["ini"] for s in ss)
        # Profundidade: quantos ancestrais até a raiz. A retentativa aninha, e é
        # isso que faz a falha contar a história inteira em vez de três pedaços.
        def prof(s, visto=None):
            visto = visto or set()
            if s["pai"] not in porsid or s["span"] in visto:
                return 0
            return 1 + prof(porsid[s["pai"]], visto | {s["span"]})
        saida.append(dict(
            trace=tid,
            spans=len(ss),
            servicos=sorted({s["servico"] for s in ss}),
            profundidade=max(prof(s) for s in ss) + 1,
            duracao_ms=round((max(s["fim"] for s in ss) - t0) / 1e6, 2),
            arvore=[dict(servico=s["servico"], nome=s["nome"],
                         offset_ms=round((s["ini"] - t0) / 1e6, 2),
                         duracao_ms=round((s["fim"] - s["ini"]) / 1e6, 2),
                         nivel=prof(s))
                    for s in sorted(ss, key=lambda x: (prof(x), x["ini"]))],
        ))
    return saida


def bytes_da_imagem(tag):
    r = sh(["docker", "image", "inspect", tag, "--format", "{{.Size}}"])
    return int(r.stdout.strip()) if r.returncode == 0 else None


def simbolos_otel(tag, caminho):
    """Quantos símbolos `go.opentelemetry.io` o binário carrega.

    É a prova de que a comparação de tamanho é entre instrumentado e NÃO
    instrumentado — e não entre dois builds que diferem por outra coisa.
    """
    cid = sh(["docker", "create", tag]).stdout.strip()
    if not cid:
        return None, None
    try:
        destino = Path("/tmp") / f"tracing-measure-{tag.replace('/', '_').replace(':', '_')}"
        if sh(["docker", "cp", f"{cid}:{caminho}", str(destino)]).returncode != 0:
            return None, None
        tamanho = destino.stat().st_size
        r = sh(["sh", "-c", f"strings {destino} | grep -c 'go.opentelemetry.io' || true"])
        destino.unlink(missing_ok=True)
        return tamanho, int(r.stdout.strip() or 0)
    finally:
        sh(["docker", "rm", cid])


CANDIDATAS_SEM_OTEL = [
    "infra-knowlogy/api-go:ci",
    "iknow-measure/api-go:dist",
    "iknow/api-go:dist",
]


def referencia_sem_otel():
    """Acha uma imagem da api PROVADAMENTE não instrumentada.

    ─── Por que isto não pode ser presumido ────────────────────────────────
    O `sizes.sh` reconstrói as tags `iknow-measure/*` a cada execução. Depois
    da instrumentação, elas passam a ser builds COM OTel — e comparar o
    instrumentado contra o instrumentado daria delta zero. A lição anunciaria,
    com um número medido, que observabilidade é de graça.

    O critério é o binário: zero ocorrências de `go.opentelemetry.io`. Não
    achando nenhuma referência válida, esta função devolve (None, None, None) e
    o main preserva o que já estava gravado, marcando `referencia_valida:
    false`. Medição que não foi feita não vira número novo.
    """
    for tag in CANDIDATAS_SEM_OTEL:
        tamanho, simbolos = simbolos_otel(tag, "/api-go")
        if tamanho is not None and simbolos == 0:
            return tamanho, simbolos, tag
    return None, None, None


def antigo():
    """O que já estava gravado, para não perder medição que não dá para refazer."""
    try:
        return json.loads(OUT.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def main():
    print("marcando o deslocamento do arquivo de traces…", file=sys.stderr)
    desde = marcar()
    # O edge precisa estar de pé para o span raiz existir; é a única espera
    # necessária agora que nada é reiniciado.
    esperar(lambda: sh(["curl", "-fsS", "-o", "/dev/null", f"{EDGE}/edge-health"]).returncode == 0,
            30, "o edge não respondeu em /edge-health")

    print("exercitando o caminho feliz…", file=sys.stderr)
    feliz = criar("https://example.com/")
    import time
    time.sleep(4)

    print("exercitando o caminho de retentativa…", file=sys.stderr)
    falho = criar("https://example.com/nao-existe-de-proposito")
    # ─── Esperar pelo que se vai AFIRMAR, e não por um proxy disso ──────────
    # A primeira versão esperava "dois traces existirem" e depois afirmava "três
    # serviços". São coisas diferentes: os spans do edge chegam por outro
    # caminho (OTLP/HTTP, lote próprio do Caddy) e atrasam em relação aos da api
    # e do worker, que vêm por gRPC.
    #
    # O resultado era um portão que passava na bancada e reprovava dentro do
    # `make verify` — a corrida estava na espera, não no código medido. Primo
    # direto da armadilha 48: sonda que passa por acaso some numa máquina com
    # temporização diferente.
    def completo():
        ts = resumir(ler_spans(desde))
        return len(ts) >= 2 and any(len(t["servicos"]) >= 3 for t in ts)

    esperar(completo, 90,
            "nenhum trace com os 3 serviços chegou ao coletor em 90s — "
            "o edge exporta por OTLP/HTTP (4318) e pode não estar configurado")
    # Uma folga depois da condição, para o segundo trace terminar de chegar.
    time.sleep(5)

    traces = resumir(ler_spans(desde))
    if len(traces) < 2:
        raise SystemExit("tracing-measure: esperava ao menos 2 traces")

    # O de retentativa é o mais fundo; o feliz é o que tem db.update.
    tem_update = [t for t in traces if any(s["nome"] == "db.update" for s in t["arvore"])]
    caminho_feliz = tem_update[0] if tem_update else traces[-1]
    caminho_retentativa = max((t for t in traces if t is not caminho_feliz),
                              key=lambda t: t["profundidade"])

    api_com, api_com_sym = simbolos_otel("infra-knowlogy/api-go:dev", "/api-go")
    api_sem, api_sem_sym, api_sem_tag = referencia_sem_otel()

    anterior = antigo().get("custo", {})
    if api_sem is not None:
        custo_api = {
            "referencia_valida": True,
            "referencia_tag": api_sem_tag,
            "imagem_com_bytes": bytes_da_imagem("infra-knowlogy/api-go:dev"),
            "imagem_sem_bytes": bytes_da_imagem(api_sem_tag),
            "binario_com_bytes": api_com,
            "binario_sem_bytes": api_sem,
            "simbolos_otel_com": api_com_sym,
            "simbolos_otel_sem": api_sem_sym,
        }
    else:
        # Nenhuma referência não instrumentada sobrou nesta máquina. Preserva o
        # que foi medido antes e diz que preservou.
        custo_api = dict(anterior.get("api_go", {}))
        custo_api["referencia_valida"] = False
        custo_api["imagem_com_bytes"] = bytes_da_imagem("infra-knowlogy/api-go:dev")
        custo_api["binario_com_bytes"] = api_com
        custo_api["simbolos_otel_com"] = api_com_sym

    custo = {
        "api_go": custo_api,
        "worker_py": {
            "imagem_com_bytes": bytes_da_imagem("infra-knowlogy/worker-py:dev"),
            "imagem_sem_bytes": bytes_da_imagem("iknow-measure/worker-py:dist")
                                or anterior.get("worker_py", {}).get("imagem_sem_bytes"),
            "site_packages_bytes": None,
            "otel_bytes": None,
        },
    }
    # O lado Python dá uma medição que o Go não dá: quanto dos pacotes é OTel.
    r = sh(["docker", "run", "--rm", "--entrypoint", "sh", "infra-knowlogy/worker-py:dev", "-c",
            'SP=$(python -c "import site;print(site.getsitepackages()[0])"); '
            'T=$(du -sb "$SP" | cut -f1); O=0; '
            'for d in "$SP"/opentelemetry* "$SP"/grpc* "$SP"/google/protobuf "$SP"/googleapis*; do '
            '[ -e "$d" ] && O=$((O + $(du -sb "$d" | cut -f1))); done; echo "$T $O"'])
    if r.returncode == 0 and len(r.stdout.split()) == 2:
        total, otel = (int(x) for x in r.stdout.split())
        custo["worker_py"]["site_packages_bytes"] = total
        custo["worker_py"]["otel_bytes"] = otel

    dados = {
        "_comentario": "Gerado por tools/scripts/tracing-measure.py — não edite à mão.",
        "medido_em": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "caminho_feliz": caminho_feliz,
        "caminho_retentativa": caminho_retentativa,
        "codigos": {"feliz": feliz, "retentativa": falho},
        "custo": custo,
    }
    OUT.write_text(json.dumps(dados, indent=2, ensure_ascii=False) + "\n")
    print(f"gravado: {OUT.relative_to(ROOT)}", file=sys.stderr)
    print(f"  feliz:       {caminho_feliz['spans']} spans · "
          f"{len(caminho_feliz['servicos'])} serviços · {caminho_feliz['duracao_ms']}ms")
    print(f"  retentativa: {caminho_retentativa['spans']} spans · "
          f"profundidade {caminho_retentativa['profundidade']} · "
          f"{caminho_retentativa['duracao_ms']}ms")


if __name__ == "__main__":
    main()
