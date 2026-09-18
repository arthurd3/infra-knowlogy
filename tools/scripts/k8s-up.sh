#!/usr/bin/env bash
# Sobe o módulo Kubernetes do zero: cluster kind + imagens + manifests.
#
# Idempotente: com o cluster já criado, só recarrega imagens e reaplica os
# manifests. O kubeconfig vai para k8s/.kubeconfig (ignorado pelo git) — nada
# aqui toca o ~/.kube/config do usuário.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CLUSTER=infra-knowlogy
NS=infra-knowlogy
export KUBECONFIG="$ROOT/k8s/.kubeconfig"

bash tools/scripts/k8s-prereqs.sh

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

step "cluster kind '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "   já existe — reaproveitando"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --config k8s/kind/kind-config.yaml --kubeconfig "$KUBECONFIG" --wait 120s
fi

step "build das imagens (as mesmas do módulo Docker)"
docker compose -f stack/compose.yaml -f stack/compose.prod.yaml build

step "carregando as imagens no cluster"
# imagePullPolicy: Never nos manifests — se este load faltar, o pod falha alto
# com ErrImageNeverPull em vez de puxar outra coisa de um registry.
kind load docker-image --name "$CLUSTER" \
  infra-knowlogy/api-go:dev infra-knowlogy/worker-py:dev infra-knowlogy/web:dev

step "secret e configmaps gerados a partir de stack/ (fonte única)"
bash tools/scripts/init-secrets.sh >/dev/null
kubectl apply -f k8s/base/namespace.yaml
# `create --dry-run=client -o yaml | apply` em vez de `create`: torna a geração
# idempotente sem precisar de delete antes.
kubectl -n "$NS" create secret generic postgres-password \
  --from-file=postgres_password=stack/secrets/postgres_password \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap edge-caddyfile \
  --from-file=Caddyfile=stack/services/edge/Caddyfile \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap db-init \
  --from-file=stack/services/db/init/ \
  --dry-run=client -o yaml | kubectl apply -f -

step "aplicando os manifests"
kubectl apply -k k8s/base

step "esperando os rollouts"
kubectl -n "$NS" rollout status statefulset/db --timeout=180s
kubectl -n "$NS" rollout status deployment/cache --timeout=120s
kubectl -n "$NS" rollout status deployment/api --timeout=180s
kubectl -n "$NS" rollout status deployment/worker --timeout=120s
kubectl -n "$NS" rollout status deployment/web --timeout=120s
kubectl -n "$NS" rollout status deployment/edge --timeout=120s

printf '\n   stack no ar: http://127.0.0.1:8081\n'
printf '   kubectl --kubeconfig k8s/.kubeconfig -n %s get pods\n' "$NS"
