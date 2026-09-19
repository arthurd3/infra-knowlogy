#!/usr/bin/env bash
# Sobe o módulo CI/CD. Idempotente.
#
# O boot é em DUAS FASES, e isso não é capricho: o segredo que o agente usa
# para se conectar é gerado pelo controller quando o nó é criado, e não há como
# semeá-lo pelo JCasC. A alternativa — o agente buscar o próprio segredo —
# exigiria uma credencial de administrador DENTRO do agente, que é exatamente o
# que a lição sobre credenciais diz para não fazer.
#
#   fase 1: controller + buildkitd + registry
#   fase 2: lê o segredo do nó pela API e sobe o agente
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
CICD="$ROOT/cicd"
SECRETS="$CICD/secrets"
COMPOSE=(docker compose -f "$CICD/compose.yaml")

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '   \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ─── Segredos ────────────────────────────────────────────────────────────────
step "1/4  Segredos locais"
[ -f "$CICD/.env" ] || cp "$CICD/.env.example" "$CICD/.env"
mkdir -p "$SECRETS"
# A proteção real é o diretório: os arquivos são lidos por UIDs diferentes
# dentro dos containers (mesma razão do stack/secrets ser 0444).
chmod 700 "$SECRETS"

if [ ! -s "$SECRETS/jenkins_admin_password" ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '\n' > "$SECRETS/jenkins_admin_password"
  else
    head -c 24 /dev/urandom | base64 | tr -d '\n' > "$SECRETS/jenkins_admin_password"
  fi
  chmod 444 "$SECRETS/jenkins_admin_password"
  ok "senha do admin gerada"
else
  ok "senha do admin já existe"
fi

# SELinux: os segredos do Compose não aceitam `:z` (armadilha 7 do CLAUDE.md),
# então o rótulo vai à mão.
if command -v chcon >/dev/null 2>&1; then
  chcon -Rt container_file_t "$SECRETS" 2>/dev/null && ok "rótulo SELinux aplicado aos segredos" || true
fi

# shellcheck disable=SC1091
source "$ROOT/tools/scripts/lib/jenkins.sh"
PORT=$(grep -E '^JENKINS_PORT=' "$CICD/.env" | cut -d= -f2)
export JENKINS_URL="http://localhost:${PORT:-8090}"
export JK_USER=admin
JK_PASS="$(cat "$SECRETS/jenkins_admin_password")"
export JK_PASS
export JK_TOKEN=""

# ─── Fase 1 ──────────────────────────────────────────────────────────────────
step "2/4  Fase 1 — controller, buildkitd, scm e registry"
"${COMPOSE[@]}" up -d --build --wait controller buildkitd scm registry \
  || die "a fase 1 não subiu — veja 'docker compose -f cicd/compose.yaml logs'"

secs=$(jk_wait_ready 180) || die "o controller não ficou pronto em 180s"
ok "controller pronto em ${secs}s — $JENKINS_URL"

# ─── O segredo do agente ─────────────────────────────────────────────────────
step "3/4  Segredo do nó builder"
# O .jnlp do nó carrega o segredo no primeiro <argument>. É a via documentada
# para obtê-lo sem clicar na UI.
secret=$(jk_curl "$JENKINS_URL/computer/builder/jenkins-agent.jnlp" \
         | sed -n 's|.*<application-desc><argument>\([a-f0-9]\{64\}\)</argument>.*|\1|p')
[ -n "$secret" ] || die "não consegui ler o segredo do nó builder (o nó existe no casc?)"

if [ "$(cat "$SECRETS/agent_secret" 2>/dev/null || true)" != "$secret" ]; then
  printf '%s' "$secret" > "$SECRETS/agent_secret"
  chmod 444 "$SECRETS/agent_secret"
  command -v chcon >/dev/null 2>&1 && chcon -t container_file_t "$SECRETS/agent_secret" 2>/dev/null || true
  ok "segredo do agente gravado"
else
  ok "segredo do agente inalterado"
fi

# ─── Fase 2 ──────────────────────────────────────────────────────────────────
step "4/4  Fase 2 — o agente"
"${COMPOSE[@]}" up -d --build agent || die "o agente não subiu"

for i in $(seq 1 60); do
  offline=$(jk_json "/computer/builder/api/json" "offline" | jk_field offline)
  [ "$offline" = "False" ] && { ok "agente conectado em ${i}s"; break; }
  sleep 1
done
[ "${offline:-True}" = "False" ] || die "o agente não conectou em 60s — 'docker compose -f cicd/compose.yaml logs agent'"

printf '\n   jenkins: \033[36m%s\033[0m\n' "$JENKINS_URL"
printf '   usuário: \033[36madmin\033[0m · senha em \033[36mcicd/secrets/jenkins_admin_password\033[0m\n\n'
