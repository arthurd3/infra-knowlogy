#!/usr/bin/env bash
# Sobe a stack do módulo 4. Fino de propósito: o trabalho é do HCL, e este
# arquivo só resolve a via do tofu, garante o segredo e imprime o endereço.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/tofu.sh
source "$ROOT/tools/scripts/lib/tofu.sh"

bash tools/scripts/init-secrets.sh >/dev/null

printf '\033[2m  tofu via: %s\033[0m\n' "$(tofu_mode)"
tofu init -input=false >/dev/null

if [ "${1:-}" = "--plan-only" ]; then
  tofu plan
  exit 0
fi

tofu apply -auto-approve -input=false

port=$(tofu output -raw edge_url 2>/dev/null || echo "http://127.0.0.1:8082")
printf '\n  stack do módulo 4 no ar: \033[36m%s\033[0m\n' "$port"
printf '  \033[2mo Compose continua em :8080 e o kind em :8081 — as três convivem\033[0m\n\n'
