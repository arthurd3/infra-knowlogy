#!/usr/bin/env bash
# Pré-requisitos do módulo CI/CD (cicd/). Checa e INSTRUI; não instala —
# nenhum script deste repositório roda sudo.
#
# A checagem que importa é a última, e ela é a razão de este arquivo existir
# antes de qualquer outra linha do módulo: **este host consegue construir uma
# imagem sem daemon e sem privilégio?** Se a resposta for não, metade do
# desenho do módulo muda — o agente de build teria que receber o socket do
# Docker, que é o mesmo que receber root no host (ADR 0003, Regra #1 do OWASP).
#
# A resposta nesta máquina é SIM, e o caminho está no ADR 0011.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDKIT="${BUILDKIT_IMAGE:-moby/buildkit:rootless}"
FAIL=0

ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '   \033[33m!\033[0m %s\n' "$1"; }

printf '\033[1m── Pré-requisitos do módulo CI/CD\033[0m\n'

if docker info >/dev/null 2>&1; then
  ok "docker responde ($(docker version --format '{{.Server.Version}}'))"
else
  bad "docker não responde"
fi

# User namespaces: sem eles o buildkitd rootless não sai do lugar.
ns=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)
if [ "${ns:-0}" -gt 0 ]; then
  ok "user namespaces habilitados (max=$ns)"
else
  bad "user.max_user_namespaces=0 — o buildkitd rootless não consegue nem iniciar"
fi

if [ -e /dev/fuse ]; then
  ok "/dev/fuse presente (necessário se o snapshotter cair para fuse-overlayfs)"
else
  warn "/dev/fuse ausente — só importa se o overlay nativo não funcionar"
fi

# As portas do módulo. 8080 é a stack do módulo 1 e 8081 é o kind do módulo 2,
# de propósito: as lições comparam os três rodando ao mesmo tempo.
for port in 8090 5001; do
  if ss -ltn 2>/dev/null | grep -qE "[:.]$port\b"; then
    bad "porta $port em uso — o módulo precisa dela livre"
  else
    ok "porta $port livre"
  fi
done

# ── A sonda ──────────────────────────────────────────────────────────────────
# Um build de verdade, com um RUN de verdade. Sem o RUN a sonda mentiria: o
# `FROM` sozinho não monta /proc, que é justamente onde o SELinux barra.
printf '\n\033[1m── A sonda: construir sem daemon e sem privilégio\033[0m\n'

# Só avisa quando de fato vai baixar: com a imagem em cache a sonda é offline,
# e anunciar um download que não acontece confunde quem está sem rede.
if ! docker image inspect "$BUILDKIT" >/dev/null 2>&1; then
  printf '   \033[2mbaixando %s (só na primeira vez)…\033[0m\n' "$BUILDKIT"
  docker pull -q "$BUILDKIT" >/dev/null 2>&1 \
    || bad "não foi possível puxar $BUILDKIT — a primeira execução precisa de rede"
fi

# Os três `unconfined` vêm da documentação do BuildKit e NÃO são privilégio de
# root: eles liberam `unshare`/`mount` para o runc e dão um /proc próprio a
# cada RUN. O quarto é a descoberta desta máquina — ver ADR 0011 e a armadilha
# 22 do CLAUDE.md. `container_engine_t` é o tipo que o Fedora criou para
# engine de container aninhada; ele mantém o SELinux CONFINADO, diferente do
# `label=disable` que todo tutorial cola.
probe() {  # $1 = rótulo, $2… = --security-opt extras
  local nome="$1"; shift
  docker run --rm \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --security-opt systempaths=unconfined \
    "$@" \
    -v "$ROOT/cicd/fixtures/hello":/ctx:ro,z \
    --entrypoint buildctl-daemonless.sh \
    "$BUILDKIT" \
    build --frontend dockerfile.v0 \
      --local context=/ctx --local dockerfile=/ctx \
      --output type=tar,dest=/dev/null >/tmp/cicd-probe.txt 2>&1
}

if probe "confinado" --security-opt label=type:container_engine_t; then
  ok "build sem daemon e sem privilégio, com SELinux CONFINADO (container_engine_t)"
elif probe "sem rótulo"; then
  ok "build sem daemon e sem privilégio (SELinux não interferiu neste host)"
  warn "container_engine_t não funcionou aqui — vale entender por quê antes de seguir"
elif probe "sem selinux" --security-opt label=disable; then
  bad "só funcionou com label=disable, que DESLIGA o confinamento SELinux"
  warn "o ADR 0011 previu este degrau; releia-o antes de aceitar a concessão"
else
  bad "não foi possível construir sem privilégio neste host"
  sed 's/^/       /' /tmp/cicd-probe.txt | tail -12
  warn "sem isto, o agente de build precisaria do socket do Docker — ver ADR 0011"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '   \033[32mtudo pronto para o módulo CI/CD.\033[0m\n\n'
else
  printf '   \033[31mresolva os itens acima antes de rodar make cicd-verify.\033[0m\n\n'
fi
exit "$FAIL"
