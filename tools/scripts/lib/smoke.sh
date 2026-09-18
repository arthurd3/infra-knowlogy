# lib/smoke.sh — o smoke test do fluxo completo, compartilhado pelos dois
# portões (verify.sh e k8s-verify.sh). Os dois provam o MESMO fluxo — criar
# link -> 302 -> worker enriquece -> SSRF bloqueado — porque a aplicação é a
# mesma; só o endereço muda.
#
# Contrato com o chamador (não é um script executável, é um `source`):
#   BASEURL      — ex.: http://127.0.0.1:8080
#   ok / bad     — as funções de contagem do portão
#   smoke_logs   — recebe nomes de serviço e imprime as últimas linhas de log
#                  de cada um (para diagnóstico quando uma checagem falha)

run_smoke() {
  local created CODE status enriched ssrf blocked

  created=$(curl -fsS -X POST "$BASEURL/api/links" \
    -H 'content-type: application/json' \
    -d '{"url":"https://example.com/"}' 2>/dev/null)

  if [ -n "$created" ] && CODE=$(printf '%s' "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])' 2>/dev/null); then
    ok "POST /api/links -> code=$CODE"

    status=$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/r/$CODE")
    if [ "$status" = "302" ]; then
      ok "GET /r/$CODE -> 302 (redirect)"
    else
      bad "GET /r/$CODE -> $status (esperado 302)"
    fi

    # O worker é assíncrono: damos a ele alguns segundos para enriquecer.
    enriched=""
    for _ in $(seq 1 15); do
      enriched=$(curl -fsS "$BASEURL/api/links/$CODE" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("title") or "")' 2>/dev/null)
      [ -n "$enriched" ] && break
      sleep 1
    done
    if [ -n "$enriched" ]; then
      ok "worker enriqueceu o link -> título: \"$enriched\""
    else
      bad "worker não enriqueceu o link em 15s"
      smoke_logs worker
    fi

    # A defesa contra SSRF: uma URL interna precisa ser recusada.
    ssrf=$(curl -fsS -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
      -d '{"url":"http://169.254.169.254/latest/meta-data/"}' 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])' 2>/dev/null)
    if [ -n "$ssrf" ]; then
      blocked=""
      for _ in $(seq 1 15); do
        blocked=$(curl -fsS "$BASEURL/api/links/$ssrf" 2>/dev/null \
          | python3 -c 'import sys,json; print(json.load(sys.stdin).get("enrich_error") or "")' 2>/dev/null)
        [ -n "$blocked" ] && break
        sleep 1
      done
      case "$blocked" in
        *bloqueado*|*blocked*) ok "SSRF recusado: $blocked" ;;
        "")                    bad "SSRF não foi avaliado em 15s" ;;
        *)                     bad "SSRF não foi bloqueado: $blocked" ;;
      esac
    fi
  else
    bad "POST /api/links falhou"
    smoke_logs api edge
  fi

  if curl -fsS "$BASEURL/" >/dev/null 2>&1; then ok "site servido pelo edge"; else bad "site não responde em /"; fi
}
