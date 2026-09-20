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

step "metrics-server (o HPA não funciona sem ele)"
# O kind NÃO traz metrics-server. Sem ele o HPA fica com `targets: <unknown>`
# para sempre — e um HPA em `<unknown>` não escala nem reclama.
#
# A imagem é carregada do host em vez de puxada pelo nó: assim o portão não
# depende de registry.k8s.io estar no ar, e o digest pinado no manifesto é o
# mesmo que o `make pins` confere.
MS_IMG=$(grep -oE 'registry\.k8s\.io/metrics-server/metrics-server:[^ ]+' k8s/addons/metrics-server.yaml | head -1)
docker image inspect "$MS_IMG" >/dev/null 2>&1 || docker pull -q "$MS_IMG" >/dev/null
kind load docker-image --name "$CLUSTER" "$MS_IMG" >/dev/null 2>&1 || true
kubectl apply -f k8s/addons/metrics-server.yaml
kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s

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

step "esperando a API de métricas responder"
# Rollout pronto NÃO é métrica disponível: o metrics-server precisa de pelo
# menos uma janela de `--metric-resolution` (15s) raspando os kubelets antes de
# ter o que servir, e o APIService só então sai de `False`. É a armadilha 25 do
# CLAUDE.md noutra roupa — prontidão de processo não é função disponível.
for _ in $(seq 1 40); do
  kubectl -n "$NS" top pod >/dev/null 2>&1 && break
  sleep 3
done
# Sem pipe para `head`: com `pipefail`, o `head` fecha o cano e o `kubectl`
# morre de SIGPIPE — a armadilha 29 do CLAUDE.md. Guarde primeiro, corte depois.
TOPO=$(kubectl -n "$NS" top pod 2>/dev/null || true)
[ -n "$TOPO" ] && sed -n '1,3p' <<<"$TOPO" | sed 's/^/   /' || echo "   (métricas ainda indisponíveis)"

printf '\n   stack no ar: http://127.0.0.1:8081\n'
printf '   kubectl --kubeconfig k8s/.kubeconfig -n %s get pods\n' "$NS"
