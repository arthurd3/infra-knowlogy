#!/usr/bin/env bash
# Pré-requisitos do módulo IaC (iac/). Checa e INSTRUI; não instala —
# nenhum script deste repositório roda sudo.
#
# Como o `cicd-prereqs.sh`, existe por causa de UMA pergunta cuja resposta muda
# o desenho do módulo: **por onde o `tofu` alcança o daemon do Docker nesta
# máquina, e a que preço?** O provider Docker precisa da API inteira — criar
# container é o trabalho dele —, então não existe aqui o truque do
# docker-socket-proxy que a observabilidade usa (ADR 0003).
#
# A sonda abaixo tenta os quatro rótulos SELinux em ordem do mais confinado
# para o menos, e imprime qual passou COM as categorias MCS intactas. Ver o
# ADR 0016 e a armadilha 33 do CLAUDE.md.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/tofu.sh
source "$ROOT/tools/scripts/lib/tofu.sh"

FAIL=0
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '   \033[33m!\033[0m %s\n' "$1"; }
dim()  { printf '     \033[2m%s\033[0m\n' "$1"; }

printf '\033[1m── Pré-requisitos do módulo IaC\033[0m\n'

if docker info >/dev/null 2>&1; then
  ok "docker responde ($(docker version --format '{{.Server.Version}}'))"
else
  bad "docker não responde"
fi

# 8080 é o Compose, 8081 é o kind, 8090 é o Jenkins. O módulo 4 fica na 8082
# de propósito: a lição 6 compara as três reconciliações com as três no ar.
if ss -ltn 2>/dev/null | grep -qE '[:.]8082\b'; then
  bad "porta 8082 em uso — o módulo precisa dela livre"
  dim "quem está lá: $(ss -ltnp 2>/dev/null | grep -E '[:.]8082\b' | head -1)"
else
  ok "porta 8082 livre"
fi

# ─── Via 1: binário no host ──────────────────────────────────────────────────
printf '\n\033[1m── Via 1: o tofu no host (preferida — concessão nenhuma)\033[0m\n'
if type -P tofu >/dev/null 2>&1; then
  ok "tofu no PATH ($(command tofu version 2>/dev/null | head -1))"
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    ok "você está no grupo docker — o tofu fala com o daemon direto"
  else
    warn "você não está no grupo docker; o tofu no host vai levar permission denied"
  fi
else
  warn "tofu não instalado — este host vai usar a via 2 (container)"
  dim "para instalar sem sudo:  https://opentofu.org/docs/intro/install/standalone/"
  dim "no Fedora:               sudo dnf install opentofu"
fi

# ─── Via 2: a sonda do socket ────────────────────────────────────────────────
# Sem o RUN de verdade a sonda mentiria: o que o SELinux barra é o connect(),
# não o mount. Por isso ela chama o /_ping e não só um `ls`.
printf '\n\033[1m── Via 2: a sonda — alcançar o socket de dentro de um container\033[0m\n'

PROBE_IMAGE="${PROBE_IMAGE:-alpine/curl:latest}"
if ! docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
  printf '   \033[2mbaixando %s (só na primeira vez)…\033[0m\n' "$PROBE_IMAGE"
  docker pull -q "$PROBE_IMAGE" >/dev/null 2>&1 \
    || warn "não foi possível puxar $PROBE_IMAGE — a primeira execução precisa de rede"
fi

probe_socket() {  # $1 = rótulo humano; $2… = --security-opt
  local nome="$1"; shift
  local label out
  label=$(docker run --rm "$@" -v "$DOCKER_SOCK":/var/run/docker.sock \
            --entrypoint cat "$PROBE_IMAGE" /proc/self/attr/current 2>/dev/null | tr -d '\0')
  out=$(docker run --rm "$@" -v "$DOCKER_SOCK":/var/run/docker.sock \
          --entrypoint curl "$PROBE_IMAGE" -sS --max-time 5 \
          --unix-socket /var/run/docker.sock http://localhost/_ping 2>&1)
  if [ "$out" = "OK" ]; then
    # Categorias MCS (o `:cNNN,cNNN` no fim) são o que separa confinamento de
    # fallback. Sem elas o container alcança arquivo de QUALQUER outro.
    if [[ "$label" == *":c"* ]]; then
      printf '   \033[32m✓\033[0m %-22s %s  \033[32m(MCS preservado)\033[0m\n' "$nome" "$label"
    else
      printf '   \033[33m!\033[0m %-22s %s  \033[33m(SEM categorias MCS)\033[0m\n' "$nome" "$label"
    fi
    return 0
  fi
  printf '   \033[31m✗\033[0m %-22s %s  \033[2m(connect negado)\033[0m\n' "$nome" "${label:-?}"
  return 1
}

probe_socket "padrão"             || true
probe_socket "container_engine_t" --security-opt label=type:container_engine_t || true
SPC_OK=0
probe_socket "label=type:spc_t"   --security-opt label=type:spc_t && SPC_OK=1
probe_socket "label=disable"      --security-opt label=disable || true

printf '\n'
if [ "$SPC_OK" -eq 1 ]; then
  ok "a via 2 funciona com SELinux enforcing e MCS preservado"
  dim "é exatamente o que tools/scripts/lib/tofu.sh usa"
elif [ "$(tofu_mode)" = "host" ]; then
  warn "a via 2 não funciona aqui — mas você tem o tofu no host, que é a via preferida"
else
  bad "nem o tofu no host nem o container alcançam o daemon"
  dim "sem uma das duas, o módulo 4 não roda nesta máquina"
fi

# Grupo do socket: a segunda camada, que não tem nada a ver com SELinux.
SOCK_GID=$(stat -c '%g' "$DOCKER_SOCK" 2>/dev/null || echo "?")
ok "gid do socket = $SOCK_GID (o --group-add do tofu.sh lê isto, não um número fixo)"

# ─── O tofu responde? ────────────────────────────────────────────────────────
printf '\n\033[1m── O tofu responde (via %s)\033[0m\n' "$(tofu_mode)"
if [ "$(tofu_mode)" = "container" ] && ! docker image inspect "$TOFU_IMAGE" >/dev/null 2>&1; then
  printf '   \033[2mbaixando %s (só na primeira vez)…\033[0m\n' "${TOFU_IMAGE%%@*}"
  docker pull -q "$TOFU_IMAGE" >/dev/null 2>&1 || bad "não foi possível puxar a imagem do OpenTofu"
fi
if ver=$(tofu version 2>&1 | head -1) && [ -n "$ver" ]; then
  ok "$ver"
else
  bad "o tofu não respondeu"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '   \033[32mtudo pronto para o módulo IaC.\033[0m\n\n'
else
  printf '   \033[31mresolva os itens acima antes de rodar make iac-verify.\033[0m\n\n'
fi
exit "$FAIL"
