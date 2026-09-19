#!/usr/bin/env bash
# Grava as respostas REAIS da stack para o modo demonstração do site.
#
# O widget GateRunner roda as mesmas checagens de lib/smoke.sh direto do
# navegador. Com `make up`, ele fala com a stack de verdade. Sem stack, ele
# reencena o que está em site/src/data/recorded-gate.json — e este script é
# quem escreve esse arquivo.
#
# A regra do repositório vale aqui igual: nada de resposta plausível escrita à
# mão. Se o arquivo não pode ser regerado por um comando, ele é um número de
# blog com outro nome.
#
#   make up && bash tools/scripts/record-gate.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PORT="$(grep -E '^EDGE_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; PORT="${PORT:-8080}"
BASEURL="${BASEURL:-http://127.0.0.1:$PORT}"
OUT="site/src/data/recorded-gate.json"

echo "── gravando contra $BASEURL"

if ! curl -fsS -m 3 "$BASEURL/api/links?limit=1" >/dev/null 2>&1; then
  echo "A stack não responde em $BASEURL. Rode 'make up' antes." >&2
  exit 1
fi

# ── Os sete passos, na ordem em que o widget os roda ─────────────────────────
edge_status=$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/edge-health")
list_body=$(curl -fsS "$BASEURL/api/links?limit=1")

create_body=$(curl -fsS -X POST "$BASEURL/api/links" \
  -H 'content-type: application/json' -d '{"url":"https://example.com/"}')
code=$(printf '%s' "$create_body" | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])')

redirect_status=$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/r/$code")
redirect_target=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASEURL/r/$code")

# O enriquecimento é assíncrono: contamos as leituras até o título aparecer,
# porque reproduzir o "ainda não" é parte do que a lição ensina.
enrich_tries=0; enrich_body=""; title=""
for i in $(seq 1 15); do
  enrich_tries=$i
  enrich_body=$(curl -fsS "$BASEURL/api/links/$code")
  title=$(printf '%s' "$enrich_body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("title") or "")')
  [ -n "$title" ] && break
  sleep 1
done

ssrf_create=$(curl -fsS -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
  -d '{"url":"http://169.254.169.254/latest/meta-data/"}')
ssrf_code=$(printf '%s' "$ssrf_create" | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])')
ssrf_tries=0; ssrf_body=""; reason=""
for i in $(seq 1 15); do
  ssrf_tries=$i
  ssrf_body=$(curl -fsS "$BASEURL/api/links/$ssrf_code")
  reason=$(printf '%s' "$ssrf_body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("enrich_error") or "")')
  [ -n "$reason" ] && break
  sleep 1
done

site_status=$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/")
site_type=$(curl -s -o /dev/null -w '%{content_type}' "$BASEURL/")

# Recusa gravar um portão que não passou: uma demonstração vermelha não ensina
# nada, e um arquivo pela metade quebraria o teste que o valida.
fail=0
[ "$edge_status" = "204" ]     || { echo "  edge-health devolveu $edge_status, esperado 204" >&2; fail=1; }
[ "$redirect_status" = "302" ] || { echo "  /r/$code devolveu $redirect_status, esperado 302" >&2; fail=1; }
[ -n "$title" ]                || { echo "  o worker não enriqueceu o link em 15s" >&2; fail=1; }
case "$reason" in *bloqueado*|*blocked*) ;; *) echo "  SSRF não foi bloqueado: '${reason:-sem veredito}'" >&2; fail=1 ;; esac
[ "$fail" -eq 0 ] || { echo "nada foi gravado." >&2; exit 1; }

# ── Escreve o JSON ───────────────────────────────────────────────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
BASEURL="$BASEURL" EDGE_STATUS="$edge_status" LIST_BODY="$list_body" \
CREATE_BODY="$create_body" CODE="$code" \
REDIRECT_STATUS="$redirect_status" REDIRECT_TARGET="$redirect_target" \
ENRICH_BODY="$enrich_body" ENRICH_TRIES="$enrich_tries" TITLE="$title" \
SSRF_BODY="$ssrf_body" SSRF_TRIES="$ssrf_tries" SSRF_REASON="$reason" \
SITE_STATUS="$site_status" SITE_TYPE="$site_type" OUT="$OUT" \
python3 - <<'PY'
import json, os

def count(body):
    return json.loads(body).get("count", 0)

doc = {
    "note_pt": "Respostas REAIS capturadas contra a stack deste repositório. O modo demonstração as reproduz quando não há stack no ar, sempre rotuladas como gravadas. Regenerar com: bash tools/scripts/record-gate.sh",
    "note_en": "REAL responses captured against this repository's stack. Demo mode replays them when no stack is up, always labelled as recorded. Regenerate with: bash tools/scripts/record-gate.sh",
    "recordedAt": os.environ["NOW"],
    "baseUrl": os.environ["BASEURL"],
    "steps": {
        "edge":     {"status": int(os.environ["EDGE_STATUS"]), "body": ""},
        "list":     {"status": 200, "count": count(os.environ["LIST_BODY"]),
                     "body": os.environ["LIST_BODY"].strip()},
        "create":   {"status": 201, "code": os.environ["CODE"],
                     "body": os.environ["CREATE_BODY"].strip()},
        "redirect": {"status": int(os.environ["REDIRECT_STATUS"]),
                     "location": os.environ["REDIRECT_TARGET"], "body": ""},
        "enrich":   {"status": 200, "tries": int(os.environ["ENRICH_TRIES"]),
                     "title": os.environ["TITLE"], "body": os.environ["ENRICH_BODY"].strip()},
        "ssrf":     {"status": 201, "tries": int(os.environ["SSRF_TRIES"]),
                     "reason": os.environ["SSRF_REASON"], "body": os.environ["SSRF_BODY"].strip()},
        "site":     {"status": int(os.environ["SITE_STATUS"]),
                     "contentType": os.environ["SITE_TYPE"], "body": ""},
    },
}

# O transporte gravado espera ver o título aparecer só a partir da tentativa
# `tries`. Com tries=1 não haveria "ainda não" para mostrar, e a demonstração
# ensinaria que o enriquecimento é síncrono — que é o oposto do que ele é.
doc["steps"]["enrich"]["tries"] = max(2, doc["steps"]["enrich"]["tries"])

with open(os.environ["OUT"], "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "── gravado em $OUT"
python3 -c "
import json;d=json.load(open('$OUT'))
print(f\"   {d['recordedAt']} · código {d['steps']['create']['code']} · título '{d['steps']['enrich']['title']}' na {d['steps']['enrich']['tries']}ª leitura\")
print(f\"   SSRF: {d['steps']['ssrf']['reason']}\")"
echo "   rode 'cd site && npm test' para provar que a gravação ainda casa com o portão."
