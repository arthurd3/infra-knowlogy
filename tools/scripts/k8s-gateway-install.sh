#!/usr/bin/env bash
# Instala a Gateway API (CRDs + controlador) no cluster kind.
#
# Separado do k8s-up.sh porque é caro: ~4 MB de manifesto e um controlador que
# leva dezenas de segundos para ficar pronto. Quem está estudando o porte da
# stack não precisa disso; quem está estudando roteamento, precisa.
#
# O manifesto é BAIXADO e CONFERIDO contra o sha256 de k8s/addons/gateway-pins.json.
# Ver o comentário daquele arquivo para o porquê de não estar versionado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export KUBECONFIG="${KUBECONFIG:-$ROOT/k8s/.kubeconfig}"

PIN="k8s/addons/gateway-pins.json"
URL=$(python3 -c "import json;print(json.load(open('$PIN'))['envoyGateway']['url'])")
SOMA=$(python3 -c "import json;print(json.load(open('$PIN'))['envoyGateway']['sha256'])")
VER=$(python3 -c "import json;print(json.load(open('$PIN'))['envoyGateway']['version'])")

CACHE="${GATEWAY_CACHE:-$ROOT/k8s/.cache}"
mkdir -p "$CACHE"
ARQ="$CACHE/envoy-gateway-$VER.yaml"

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

step "manifesto do Envoy Gateway $VER"
# Reusa o download anterior se o hash bater — o cache é validado, não confiado.
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
    echo "     O release foi republicado, ou o download foi adulterado. Não aplico." >&2
    exit 1
  fi
  mv "$ARQ.tmp" "$ARQ"
  echo "   sha256 confere"
fi

step "aplicando CRDs e controlador"
kubectl apply --server-side -f "$ARQ"
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=300s

step "GatewayClass, Gateway e HTTPRoute da stack"
# `kubectl wait --for=condition=Established` nos CRDs: o apply retorna antes de
# o API server passar a SERVIR o recurso novo, e aplicar um Gateway cedo demais
# falha com "no matches for kind". É a armadilha 25 mais uma vez: resposta
# aceita não é função disponível.
kubectl wait --for=condition=Established --timeout=120s \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  crd/envoyproxies.gateway.envoyproxy.io >/dev/null

kubectl apply -f k8s/gateway/

step "esperando o Gateway ser programado"
kubectl -n infra-knowlogy wait --for=condition=Programmed --timeout=300s gateway/stack
kubectl -n infra-knowlogy get gateway stack
kubectl -n infra-knowlogy get httproute

printf '\n   gateway no ar: http://127.0.0.1:8083\n'
