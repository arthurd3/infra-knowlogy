#!/usr/bin/env bash
# Pré-requisitos do módulo Kubernetes (k8s/). Checa e INSTRUI; não instala —
# nenhum script deste repositório roda sudo.
#
# Exigência dura: kind >= 0.23.0. A partir dessa versão o kindnetd embute o
# kube-network-policies e passa a APLICAR NetworkPolicy. Abaixo disso as
# policies são aceitas pela API e ignoradas em silêncio — e as lições afirmam
# coisas como "o edge não alcança o db". Ver docs/adr/0007.
set -uo pipefail

KIND_MIN="0.23.0"
FAIL=0

ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '   \033[33m!\033[0m %s\n' "$1"; }

printf '\033[1m── Pré-requisitos do módulo Kubernetes\033[0m\n'

# Docker de pé (o kind roda o cluster dentro de containers Docker).
if docker info >/dev/null 2>&1; then
  ok "docker responde"
else
  bad "docker não responde — o kind precisa dele para criar o cluster"
fi

# kind presente e na versão mínima.
if command -v kind >/dev/null 2>&1; then
  v=$(kind version 2>/dev/null | awk '{print $2}' | tr -d v)
  if [ "$(printf '%s\n%s\n' "$KIND_MIN" "$v" | sort -V | head -1)" = "$KIND_MIN" ]; then
    ok "kind v$v (>= $KIND_MIN: NetworkPolicy é aplicada)"
  else
    bad "kind v$v é ANTIGO demais — abaixo de v$KIND_MIN NetworkPolicy é ignorada em silêncio"
  fi
else
  bad "kind não encontrado"
fi

if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client 2>/dev/null | awk '/Client/{print $3}')"
else
  bad "kubectl não encontrado"
fi

# Armadilha clássica do kind em Fedora: limites de inotify baixos derrubam o
# kubelet/containerd quando há muitos pods ("too many open files").
watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
if [ "$watches" -lt 524288 ] || [ "$instances" -lt 512 ]; then
  warn "inotify baixo (watches=$watches, instances=$instances) — se o cluster falhar com 'too many open files':"
  warn "    sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"
else
  ok "limites de inotify suficientes (watches=$watches, instances=$instances)"
fi

if [ "$FAIL" -ne 0 ]; then
  cat <<'EOF'

   Como instalar no Fedora (escolha UMA das formas):

     # via dnf (mais simples; a versão precisa ser >= 0.23):
     sudo dnf install kind kubernetes-client

     # ou binários estáticos em ~/.local/bin, sem sudo — verificando o checksum:
     curl -fsSLo kind        https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64
     curl -fsSLo kind.sha256 https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64.sha256sum
     sed 's|kind-linux-amd64|kind|' kind.sha256 | sha256sum -c -
     curl -fsSLo kubectl     https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl
     curl -fsSLo kubectl.sha256 https://dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl.sha256
     echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
     install -m 0755 kind kubectl ~/.local/bin/
EOF
  exit 1
fi
echo "   pré-requisitos ok."
