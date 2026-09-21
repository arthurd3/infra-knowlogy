#!/usr/bin/env bash
# Instala o ArgoCD no cluster kind e registra a Application que aponta para
# este repositório.
#
# Separado do k8s-up.sh porque é caro e opcional: ~1,9 MB de manifesto e sete
# controladores. Quem está estudando o porte da stack não precisa; quem está
# estudando reconciliação, precisa.
#
# O manifesto é BAIXADO e CONFERIDO contra o sha256 de gitops/gitops-pins.json,
# no mesmo padrão que o ADR 0021 estabeleceu para o Envoy Gateway.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export KUBECONFIG="${KUBECONFIG:-$ROOT/k8s/.kubeconfig}"

PIN="gitops/gitops-pins.json"
URL=$(python3 -c "import json;print(json.load(open('$PIN'))['argocd']['url'])")
SOMA=$(python3 -c "import json;print(json.load(open('$PIN'))['argocd']['sha256'])")
VER=$(python3 -c "import json;print(json.load(open('$PIN'))['argocd']['version'])")

CACHE="${GITOPS_CACHE:-$ROOT/k8s/.cache}"
mkdir -p "$CACHE"
ARQ="$CACHE/argocd-$VER.yaml"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

step "manifesto do ArgoCD $VER"
# Cache validado, não confiado: o hash é conferido mesmo quando o arquivo já
# está no disco.
if [ -f "$ARQ" ] && [ "$(sha256sum "$ARQ" | cut -d' ' -f1)" = "$SOMA" ]; then
  echo "   cache íntegro em $ARQ"
else
  echo "   baixando $URL"
  curl -sS -L --max-time 300 -o "$ARQ.tmp" "$URL"
  OBTIDO=$(sha256sum "$ARQ.tmp" | cut -d' ' -f1)
  if [ "$OBTIDO" != "$SOMA" ]; then
    rm -f "$ARQ.tmp"
    echo "   ✗ sha256 NÃO confere" >&2
    echo "     esperado: $SOMA" >&2
    echo "     obtido:   $OBTIDO" >&2
    exit 1
  fi
  mv "$ARQ.tmp" "$ARQ"
  echo "   sha256 confere"
fi

step "aplicando o ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# `--server-side` porque o install.yaml do ArgoCD tem CRDs grandes o bastante
# para estourar o limite de 262 kB da anotação `last-applied-configuration`
# que o apply do lado do cliente usa. O erro, se você usar o apply comum, fala
# de tamanho de anotação e não de CRD — e manda procurar no lugar errado.
kubectl apply -n argocd --server-side -f "$ARQ" >/dev/null

step "esperando os controladores"
for d in argocd-repo-server argocd-server argocd-applicationset-controller; do
  kubectl -n argocd rollout status "deployment/$d" --timeout=300s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

step "registrando a Application"
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io >/dev/null
# A URL sai do remote de VERDADE, e a revisão também. Um manifesto com a URL
# de outra pessoa gravada dentro faz um fork sincronizar o repositório alheio —
# que é um jeito silencioso e constrangedor de o portão passar.
REPO=$(git config --get remote.origin.url 2>/dev/null || true)
case "$REPO" in
  git@github.com:*) REPO="https://github.com/${REPO#git@github.com:}" ;;
esac
case "$REPO" in
  *.git) : ;;
  http*) REPO="$REPO.git" ;;
  *) echo "   ✗ sem remote origin: o ArgoCD precisa de um repositório para ler" >&2; exit 1 ;;
esac
RAMO=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
echo "   fonte: $REPO ($RAMO)"
sed -e "s|REPO_URL_AQUI|$REPO|" -e "s|targetRevision: main|targetRevision: $RAMO|" \
  gitops/application.yaml | kubectl apply -f - >/dev/null

# E a conferência que evita o constrangimento silencioso: o ArgoCD precisa
# estar lendo o repositório DESTE clone.
LENDO=$(kubectl -n argocd get application stack -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
[ "$LENDO" = "$REPO" ] || { echo "   ✗ a Application aponta para $LENDO, não para $REPO" >&2; exit 1; }

step "esperando a primeira sincronização"
for _ in $(seq 1 60); do
  ESTADO=$(kubectl -n argocd get application stack \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  printf '   %s\n' "${ESTADO:-...}"
  case "$ESTADO" in Synced/*) break ;; esac
  sleep 5
done

kubectl -n argocd get application stack \
  -o custom-columns='NOME:.metadata.name,SYNC:.status.sync.status,SAUDE:.status.health.status,REVISAO:.status.sync.revision'

printf '\n   a senha inicial do admin: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d\n'
printf '   a interface: kubectl -n argocd port-forward svc/argocd-server 8084:443\n'
