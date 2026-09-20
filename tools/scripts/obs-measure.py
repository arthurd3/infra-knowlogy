#!/usr/bin/env python3
"""Mede o profile `obs` que está no ar e grava site/src/data/obs-measured.json.

Mesmo papel do sizes.sh para tamanho de imagem: as lições da trilha de
Observabilidade citam este arquivo, e nenhum número delas é escrito à mão.

Precisa do Prometheus respondendo em 127.0.0.1:9090 — ou seja, `make obs`.
Sem ele, sai com 2 e não grava nada: arquivo de medição meio-preenchido é pior
que arquivo ausente, porque ele parece atual.
"""
import json
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "site/src/data/obs-measured.json"
PROM = "http://127.0.0.1:9090"


def get(path, **params):
    url = f"{PROM}{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    r = subprocess.run(["curl", "-fsS", "--max-time", "10", url],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"prometheus não respondeu em {PROM} — rode `make obs` antes.")
    return json.loads(r.stdout)


def q(expr):
    return get("/api/v1/query", query=expr)["data"]["result"]


def scalar(expr, default=None):
    r = q(expr)
    return float(r[0]["value"][1]) if r else default


alvos = get("/api/v1/targets", state="active")["data"]["activeTargets"]

# A história da cardinalidade: quanto cada job publica, e quanto sobra depois do
# metric_relabel_configs. É a única forma honesta de mostrar o custo de um
# exporter sem cortar — e o Prometheus já mede isso sozinho.
antes = {m["metric"]["job"]: int(float(m["value"][1])) for m in q("scrape_samples_scraped")}
depois = {m["metric"]["job"]: int(float(m["value"][1]))
          for m in q("scrape_samples_post_metric_relabeling")}
jobs = sorted(set(antes) | set(depois))
coleta = [{"job": j, "scraped": antes.get(j, 0), "kept": depois.get(j, 0),
           "dropped": antes.get(j, 0) - depois.get(j, 0)} for j in jobs]

# A história do denominador: quanto do tráfego da api é usuário de verdade e
# quanto é ela respondendo ao próprio monitoramento.
INFRA = {"/healthz", "/readyz", "/metrics"}
rotas = []
for m in q("api_http_requests_total"):
    l = m["metric"]
    rotas.append({"route": l.get("route", "?"), "method": l.get("method", "?"),
                  "status": l.get("status", "?"), "total": int(float(m["value"][1]))})
rotas.sort(key=lambda r: -r["total"])
infra_total = sum(r["total"] for r in rotas if r["route"] in INFRA)
user_total = sum(r["total"] for r in rotas if r["route"] not in INFRA)

# A razão infra/usuário é VOLÁTIL — ela depende de quanto tráfego de usuário
# houve pouco antes de medir. O número estável é outro: o tráfego de
# infraestrutura é um PISO CONSTANTE, ditado pelo intervalo do healthcheck
# (10s) e pelo do scrape (15s). Ele não depende de ter um usuário ou um milhão,
# e é isso que faz ele dominar o denominador num serviço de baixo tráfego.
infra_rate = scalar(
    'sum(rate(api_http_requests_total{route=~"/healthz|/readyz|/metrics"}[10m])) * 60')

grupos = get("/api/v1/rules")["data"]["groups"]
regras = {"recording": 0, "alerting": 0}
for g in grupos:
    for r in g["rules"]:
        regras["recording" if r["type"] == "recording" else "alerting"] += 1

quantis = {}
for nome, v in (("p50", 0.5), ("p90", 0.9), ("p99", 0.99)):
    s = scalar(f"histogram_quantile({v}, sum by (le) "
               f"(rate(api_http_request_duration_seconds_bucket[30m])))")
    if s is not None and s == s:  # NaN não é igual a si mesmo
        quantis[nome + "Seconds"] = round(s, 5)

doc = {
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "prometheusVersion": (q('prometheus_build_info') or [{}])[0]
                          .get("metric", {}).get("version", "?"),
    "targets": {"total": len(alvos), "up": sum(1 for a in alvos if a["health"] == "up"),
                "jobs": [a["labels"]["job"] for a in sorted(alvos, key=lambda a: a["labels"]["job"])]},
    "tsdb": {
        "activeSeries": int(scalar("prometheus_tsdb_head_series") or 0),
        "samplesPerSecond": round(scalar("rate(prometheus_tsdb_head_samples_appended_total[5m])") or 0, 1),
        "residentBytes": int(scalar('process_resident_memory_bytes{job="prometheus"}') or 0),
    },
    "collection": {
        "perJob": coleta,
        "scrapedTotal": sum(c["scraped"] for c in coleta),
        "keptTotal": sum(c["kept"] for c in coleta),
        "droppedTotal": sum(c["dropped"] for c in coleta),
    },
    "apiTraffic": {
        "byRoute": rotas,
        "infrastructureTotal": infra_total,
        "userTotal": user_total,
        # A razão que a lição de SLO cita: quantas requisições de infraestrutura
        # existem para cada requisição de usuário de verdade.
        "infraPerUserRequest": round(infra_total / user_total, 1) if user_total else None,
        # Requisições de infraestrutura por minuto. Constante: é o piso que
        # existe mesmo sem nenhum usuário.
        "infrastructurePerMinute": round(infra_rate, 1) if infra_rate else None,
    },
    "rules": regras,
    "latency": quantis,
}

OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
print(f"   {OUT.relative_to(ROOT)}")
print(f"   alvos {doc['targets']['up']}/{doc['targets']['total']} up · "
      f"{doc['tsdb']['activeSeries']} séries · "
      f"{doc['tsdb']['residentBytes'] // 1048576} MB residentes")
print(f"   coleta: {doc['collection']['scrapedTotal']} raspadas -> "
      f"{doc['collection']['keptTotal']} guardadas "
      f"({doc['collection']['droppedTotal']} descartadas pelo relabel)")
print(f"   tráfego da api: {infra_total} de infraestrutura para {user_total} de usuário "
      f"({doc['apiTraffic']['infraPerUserRequest']}:1) · piso de infraestrutura: "
      f"{doc['apiTraffic']['infrastructurePerMinute']}/min")
print(f"   regras: {regras['recording']} de gravação, {regras['alerting']} de alerta")
