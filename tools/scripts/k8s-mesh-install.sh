#!/usr/bin/env bash
# Instala o Linkerd no cluster kind e sobe dois pares de serviços — um dentro
# da malha e outro fora — para a comparação da lição ser medida e não citada.
#
# Separado do k8s-up.sh porque é caro: um CLI de 87 MB, um plano de controle
# com PKI própria, e um sidecar em cada pod do namespace injetado.
#
# O binário é BAIXADO e CONFERIDO contra o sha256 de gitops/gitops-pins.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export KUBECONFIG="${KUBECONFIG:-$ROOT/k8s/.kubeconfig}"

PIN="gitops/gitops-pins.json"
URL=$(python3 -c "import json;print(json.load(open('$PIN'))['linkerd']['url'])")
SOMA=$(python3 -c "import json;print(json.load(open('$PIN'))['linkerd']['sha256'])")
VER=$(python3 -c "import json;print(json.load(open('$PIN'))['linkerd']['version'])")

CACHE="${MESH_CACHE:-$ROOT/k8s/.cache}"
mkdir -p "$CACHE"
LK="$CACHE/linkerd"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

step "CLI do Linkerd $VER"
if [ -f "$LK" ] && [ "$(sha256sum "$LK" | cut -d' ' -f1)" = "$SOMA" ]; then
  echo "   cache íntegro ($(( $(stat -c %s "$LK") / 1048576 )) MB)"
else
  echo "   baixando $URL"
  curl -sS -L --max-time 900 -o "$LK.tmp" "$URL"
  OBTIDO=$(sha256sum "$LK.tmp" | cut -d' ' -f1)
  if [ "$OBTIDO" != "$SOMA" ]; then
    rm -f "$LK.tmp"
    echo "   ✗ sha256 NÃO confere" >&2
    echo "     esperado: $SOMA" >&2
    echo "     obtido:   $OBTIDO" >&2
    exit 1
  fi
  mv "$LK.tmp" "$LK"
  echo "   sha256 confere"
fi
chmod +x "$LK"

# O Linkerd EXIGE os CRDs da Gateway API — ele os usa para HTTPRoute. Sem
# eles o `linkerd check --pre` reprova com uma mensagem que fala de Gateway
# API e não de Linkerd, e é fácil achar que o erro é noutro lugar.
step "pré-requisitos"
if ! kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "   os CRDs da Gateway API faltam — instalando o Envoy Gateway antes"
  bash tools/scripts/k8s-gateway-install.sh >/dev/null
fi
# `check --pre` é para cluster LIMPO: com o Linkerd já instalado ele reprova
# reclamando que o namespace existe, o que faz um script idempotente parecer
# quebrado. Só roda quando ainda não há nada.
if kubectl get namespace linkerd >/dev/null 2>&1; then
  echo "   o Linkerd já está instalado — pulando o check --pre"
else
  "$LK" check --pre 2>&1 | tail -3
fi

step "CRDs e plano de controle (com a PKI que o mTLS exige)"
# `linkerd install` gera a âncora de confiança e o certificado emissor na hora.
# Num cluster de verdade isso é uma decisão: a âncora tem validade e precisa
# ser rotacionada antes de vencer, e um mesh com âncora expirada para de
# aceitar conexão nova — silenciosamente, pod a pod, conforme eles reiniciam.
# `linkerd install` GERA certificados novos a cada execução. Reaplicar num
# cluster que já tem o plano de controle trocaria a âncora de confiança por
# outra, e todo proxy já injetado passaria a apresentar um certificado que o
# novo emissor não reconhece — a malha quebraria em silêncio, pod a pod,
# conforme eles reiniciassem. Por isso só instala se não houver.
if kubectl get deployment -n linkerd linkerd-identity >/dev/null 2>&1; then
  echo "   plano de controle já existe — não reinstalo (geraria PKI nova)"
else
  "$LK" install --crds | kubectl apply -f - >/dev/null
  "$LK" install | kubectl apply -f - >/dev/null
fi
for d in linkerd-destination linkerd-identity linkerd-proxy-injector; do
  kubectl -n linkerd rollout status "deployment/$d" --timeout=300s
done

step "linkerd check"
"$LK" check 2>&1 | tail -3

step "os dois pares: um na malha, outro fora"
kubectl apply -f k8s/addons/linkerd-demo.yaml >/dev/null
for ns in linkerd-demo linkerd-demo-sem; do
  kubectl -n "$ns" rollout status deploy/servidor --timeout=300s
  kubectl -n "$ns" rollout status deploy/cliente --timeout=300s
done

kubectl -n linkerd-demo get pods \
  -o custom-columns='POD:.metadata.name,APP:.spec.containers[*].name,INJETADOS:.spec.initContainers[*].name'
printf '\n   o proxy entra como SIDECAR NATIVO (init container com restartPolicy: Always)\n'
printf '   métricas do proxy: %s diagnostics proxy-metrics -n linkerd-demo po/<pod>\n' "$LK"
