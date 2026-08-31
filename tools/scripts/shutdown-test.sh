#!/usr/bin/env bash
# Cronometra o desligamento gracioso de cada serviço, um de cada vez, com o
# RESTO DA STACK DE PÉ.
#
# Essa condição não é um detalhe. Parar os serviços em sequência deixaria, por
# exemplo, o worker sem Redis na hora do próprio SIGTERM — e aí o que se mede é
# o timeout de conexão da biblioteca, não o tratamento de sinal. A pergunta que
# este teste faz é "este serviço trata SIGTERM?", então todo o resto fica no ar.
#
# O limite é 3s. Nada aqui tem motivo para demorar mais quando ocioso; passar
# disso significa que o SIGTERM não está chegando a alguém, ou que alguém está
# preso numa chamada bloqueante que não confere a flag de parada.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/stack/compose.yaml" -f "$ROOT/stack/compose.prod.yaml")
LIMIT_MS="${SHUTDOWN_LIMIT_MS:-3000}"

echo "── medindo o desligamento (limite: ${LIMIT_MS}ms por serviço)"

mapfile -t services < <("${COMPOSE[@]}" ps --services --status running 2>/dev/null | sort)
if [ ${#services[@]} -eq 0 ]; then
  echo "   nenhum serviço rodando — suba com 'make up' antes." >&2
  exit 1
fi

failed=0
for svc in "${services[@]}"; do
  start=$(date +%s%N)
  "${COMPOSE[@]}" stop -t 30 "$svc" >/dev/null 2>&1
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))

  if [ "$elapsed" -gt "$LIMIT_MS" ]; then
    printf '   ✗ %-12s %5dms  (limite %dms — SIGTERM não está sendo tratado)\n' "$svc" "$elapsed" "$LIMIT_MS"
    failed=1
  else
    printf '   ✓ %-12s %5dms\n' "$svc" "$elapsed"
  fi

  # Devolve o serviço ao ar ANTES de medir o próximo, para que cada medição
  # aconteça com as dependências disponíveis.
  "${COMPOSE[@]}" up -d --wait --wait-timeout 90 "$svc" >/dev/null 2>&1
done

if [ "$failed" -eq 1 ]; then
  echo "   → conserte tratando SIGTERM na aplicação, ou use 'init: true' no serviço." >&2
  exit 1
fi
echo "   todos os serviços desligam graciosamente."
