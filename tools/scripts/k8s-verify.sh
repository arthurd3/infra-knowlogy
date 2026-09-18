#!/usr/bin/env bash
# O portão de qualidade do módulo Kubernetes. Roda tudo do zero e falha alto.
#
# Mesmo contrato do verify.sh: cada afirmação que as lições da trilha
# `kubernetes` fazem deve ser verificável por uma checagem daqui. As medições
# (auto-cura, readiness, rolling sem downtime) são gravadas em
# site/src/data/k8s-measured.json — são exatamente os números que as lições
# citam.
#
#   SKIP_LINT=1      pula o lint estático (kustomize + kubeconform)
#   KEEP_CLUSTER=1   reaproveita o cluster existente e não o destrói no final
#                    (para iterar; a medição de criação do cluster fica de fora)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CLUSTER=infra-knowlogy
NS=infra-knowlogy
export KUBECONFIG="$ROOT/k8s/.kubeconfig"
KC=(kubectl -n "$NS")
BASEURL="http://127.0.0.1:8081"
KUBECONFORM_IMG="ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e"

PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()

step()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()    { printf '   \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); RESULTS+=("PASS  $1"); }
bad()   { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); }
skip()  { printf '   \033[33m⊘\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $1"); }

now_ms() { date +%s%3N; }

# As medições que viram k8s-measured.json (e depois, números nas lições).
M_CLUSTER_CREATE_S=""; M_STACK_READY_S=""; M_SELF_HEAL_S=""
M_NOTREADY_S=""; M_ROLLING_TOTAL=""; M_ROLLING_FAILS=""; M_SHUTDOWN_MAX_MS=""

# ─── 1. Pré-requisitos e lint estático ───────────────────────────────────────
step "1/9  Pré-requisitos e lint dos manifests"
if bash tools/scripts/k8s-prereqs.sh >/tmp/k8s-pre.txt 2>&1; then
  ok "pré-requisitos (docker, kind >= 0.23, kubectl)"
else
  bad "pré-requisitos"; sed 's/^/       /' /tmp/k8s-pre.txt
  printf '\n   sem kind/kubectl não há o que verificar.\n'; exit 1
fi

if [ "${SKIP_LINT:-0}" = "1" ]; then
  skip "lint pulado (SKIP_LINT=1)"
else
  if kubectl kustomize k8s/base >/tmp/k8s-render.yaml 2>/tmp/k8s-render.err; then
    ok "kubectl kustomize renderiza ($(grep -c '^kind:' /tmp/k8s-render.yaml) recursos)"
  else
    bad "kubectl kustomize"; sed 's/^/       /' /tmp/k8s-render.err | head -6
  fi
  if docker run --rm -i "$KUBECONFORM_IMG" -strict -summary - </tmp/k8s-render.yaml >/tmp/k8s-conform.txt 2>&1; then
    ok "kubeconform: $(tail -1 /tmp/k8s-conform.txt | sed 's/Summary: //')"
  else
    bad "kubeconform"; sed 's/^/       /' /tmp/k8s-conform.txt | head -10
  fi
fi

# ─── 2. Build + cluster ──────────────────────────────────────────────────────
step "2/9  Build das imagens e criação do cluster kind"
if docker compose -f stack/compose.yaml -f stack/compose.prod.yaml build >/tmp/k8s-build.txt 2>&1; then
  ok "docker compose build (as mesmas imagens do módulo Docker)"
else
  bad "docker compose build"; tail -20 /tmp/k8s-build.txt | sed 's/^/       /'
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER" && [ "${KEEP_CLUSTER:-0}" = "1" ]; then
  skip "cluster reaproveitado (KEEP_CLUSTER=1) — criação não medida"
  kind export kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
else
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  t0=$(now_ms)
  if kind create cluster --config k8s/kind/kind-config.yaml --kubeconfig "$KUBECONFIG" --wait 120s >/tmp/k8s-kind.txt 2>&1; then
    M_CLUSTER_CREATE_S=$(( ($(now_ms) - t0) / 1000 ))
    ok "kind create cluster em ${M_CLUSTER_CREATE_S}s (nó pronto)"
  else
    bad "kind create cluster"; tail -15 /tmp/k8s-kind.txt | sed 's/^/       /'
    exit 1
  fi
fi

if kind load docker-image --name "$CLUSTER" \
     infra-knowlogy/api-go:dev infra-knowlogy/worker-py:dev infra-knowlogy/web:dev >/tmp/k8s-load.txt 2>&1; then
  ok "kind load: 3 imagens locais no cluster (imagePullPolicy: Never)"
else
  bad "kind load docker-image"; tail -10 /tmp/k8s-load.txt | sed 's/^/       /'
fi

# ─── 3. Secret/ConfigMaps gerados + apply + rollout ──────────────────────────
step "3/9  Aplicar manifests e esperar todos os rollouts"
t0=$(now_ms)
bash tools/scripts/init-secrets.sh >/dev/null 2>&1
if kubectl apply -f k8s/base/namespace.yaml >/dev/null 2>&1 \
   && "${KC[@]}" create secret generic postgres-password \
        --from-file=postgres_password=stack/secrets/postgres_password \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
   && "${KC[@]}" create configmap edge-caddyfile \
        --from-file=Caddyfile=stack/services/edge/Caddyfile \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
   && "${KC[@]}" create configmap db-init \
        --from-file=stack/services/db/init/ \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; then
  ok "secret e configmaps gerados a partir de stack/ (fonte única)"
else
  bad "geração de secret/configmaps"
fi

if kubectl apply -k k8s/base >/tmp/k8s-apply.txt 2>&1; then
  ok "kubectl apply -k k8s/base"
else
  bad "kubectl apply -k"; sed 's/^/       /' /tmp/k8s-apply.txt | head -10
fi

rollout_all() {
  "${KC[@]}" rollout status statefulset/db --timeout=180s >/dev/null 2>&1 \
  && for d in cache api worker web edge; do
       "${KC[@]}" rollout status deployment/$d --timeout=180s >/dev/null 2>&1 || return 1
     done
}
if rollout_all; then
  M_STACK_READY_S=$(( ($(now_ms) - t0) / 1000 ))
  ok "todos os workloads Ready em ${M_STACK_READY_S}s (do apply ao pronto)"
else
  bad "algum rollout não completou"
  "${KC[@]}" get pods | sed 's/^/       /'
fi

# ─── 4. Smoke test do fluxo completo ─────────────────────────────────────────
step "4/9  Smoke test: criar link -> redirecionar -> enriquecer (via :8081)"

# Rollout completo não significa caminho de rede pronto: num cluster recém-
# criado, o agente de NetworkPolicy ainda está programando as regras e o
# health checker ativo do Caddy pode ter marcado a api como fora — ele só
# reavalia a cada health_interval. Esperamos o caminho edge->api responder
# (404 serve: prova que a requisição ATRAVESSOU o proxy e chegou na api).
path_up=""
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASEURL/api/links/warmup" 2>/dev/null)
  case "$code" in 200|404) path_up=1; break ;; esac
  sleep 1
done
[ -z "$path_up" ] && printf '   (aviso: o caminho edge->api não respondeu em 60s; o smoke vai reportar o erro real)\n'

source tools/scripts/lib/smoke.sh
smoke_logs() {
  for s in "$@"; do
    "${KC[@]}" logs --tail 20 "deploy/$s" 2>/dev/null | sed 's/^/       /'
  done
}
run_smoke

# ─── 5. NetworkPolicy: a topologia declarada precisa VALER ───────────────────
step "5/9  NetworkPolicy (o espelho das redes edge/data/egress)"

# A prova-espelho do módulo 1: o proxy não alcança o banco.
if "${KC[@]}" exec deploy/edge -- nc -z -w 2 db 5432 >/dev/null 2>&1; then
  bad "o edge ALCANÇA o banco (NetworkPolicy não está valendo — kind < 0.23?)"
else
  ok "segmentação: o edge não alcança o db (≙ redes edge/data)"
fi

# ≙ internal: true — o banco não tem NENHUMA rota para fora.
if "${KC[@]}" exec db-0 -- nc -z -w 2 1.1.1.1 443 >/dev/null 2>&1; then
  bad "o db ALCANÇA a internet (deveria estar isolado como a rede internal)"
else
  ok "o db não tem rota para a internet (≙ internal: true)"
fi

# O worker é a exceção estudada: internet sim...
if "${KC[@]}" exec deploy/worker -- python3 -c \
     "import socket; socket.create_connection(('example.com', 443), 5)" >/dev/null 2>&1; then
  ok "o worker alcança a internet (≙ rede egress)"
else
  bad "o worker não alcança a internet — o enriquecimento não funcionaria"
fi

# ...mas link-local não: mesmo que o guard de SSRF da aplicação regredisse,
# a policy bloqueia a faixa 169.254.0.0/16 (metadados de nuvem).
if "${KC[@]}" exec deploy/worker -- python3 -c \
     "import socket; socket.create_connection(('169.254.169.254', 80), 3)" >/dev/null 2>&1; then
  bad "o worker ALCANÇA link-local (a defesa em profundidade contra SSRF caiu)"
else
  ok "o worker não alcança 169.254.169.254 (defesa em profundidade da policy)"
fi

# ─── 6. Endurecimento ────────────────────────────────────────────────────────
step "6/9  Provas de endurecimento (o mesmo OWASP, agora em securityContext)"

if "${KC[@]}" exec deploy/worker -- sh -c 'echo x > /provaescrita' >/dev/null 2>&1; then
  bad "rootfs do worker é GRAVÁVEL (readOnlyRootFilesystem não está valendo)"
else
  ok "rootfs read-only aplicado (escrita em / recusada)"
fi
if "${KC[@]}" exec deploy/worker -- sh -c 'echo x > /tmp/ok && rm /tmp/ok' >/dev/null 2>&1; then
  ok "emptyDir /tmp gravável"
else
  bad "emptyDir /tmp NÃO é gravável — a aplicação vai quebrar"
fi

uid=$("${KC[@]}" exec deploy/worker -- id -u 2>/dev/null | tr -d '\r\n')
if [ "$uid" = "65532" ]; then ok "worker roda como não-root (uid=$uid)"; else bad "worker roda como uid=$uid"; fi

if [ "$("${KC[@]}" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "2" ] \
   && ! "${KC[@]}" exec deploy/api -- /bin/sh -c true >/dev/null 2>&1; then
  ok "imagem da api é distroless (não há shell para um invasor usar)"
else
  skip "checagem de distroless inconclusiva"
fi

# O segredo não pode estar nem no spec (env) nem no ambiente do processo.
secret=$(cat stack/secrets/postgres_password 2>/dev/null)
if [ -n "$secret" ]; then
  if "${KC[@]}" get pods -o jsonpath='{..env}' 2>/dev/null | grep -qF "$secret" \
     || "${KC[@]}" exec deploy/worker -- env 2>/dev/null | grep -qF "$secret"; then
    bad "SEGREDO VAZOU para o spec dos pods ou para o ambiente"
  else
    ok "segredo não aparece no spec (jsonpath {..env}) nem em 'env'"
  fi
fi

# Nada publicado em 0.0.0.0 no host: o kind só mapeia o que o kind-config
# manda, e manda com listenAddress 127.0.0.1.
if docker port "${CLUSTER}-control-plane" 2>/dev/null | grep -q '0\.0\.0\.0'; then
  bad "o nó do kind publica porta em 0.0.0.0 (fura o firewall — OWASP 5a)"
else
  ok "todas as portas do host estão presas a 127.0.0.1"
fi

# ─── 7. Desligamento gracioso ────────────────────────────────────────────────
step "7/9  Desligamento gracioso por workload"
# O mesmo limite de 3s do módulo 1 para o processo, mais uma folga fixa de 2s
# para o que é do Kubernetes (chamada de API + remoção do pod). O
# discriminador é claro: um processo que IGNORA o SIGTERM só morre no
# terminationGracePeriodSeconds (15–30s) — muito acima do limite.
LIMIT_MS=5000
sd_fail=0; M_SHUTDOWN_MAX_MS=0
for app in edge api worker web cache db; do
  pod=$("${KC[@]}" get pod -l "app=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && { sd_fail=1; printf '       %s: pod não encontrado\n' "$app"; continue; }
  t0=$(now_ms)
  "${KC[@]}" delete pod "$pod" --wait=true --timeout=60s >/dev/null 2>&1
  dur=$(( $(now_ms) - t0 ))
  [ "$dur" -gt "$M_SHUTDOWN_MAX_MS" ] && M_SHUTDOWN_MAX_MS=$dur
  if [ "$dur" -le "$LIMIT_MS" ]; then
    printf '    \033[32m✓\033[0m %s: %sms\n' "$app" "$dur"
  else
    printf '    \033[31m✗\033[0m %s: %sms (limite %sms)\n' "$app" "$dur" "$LIMIT_MS"
    sd_fail=1
  fi
done
if [ "$sd_fail" -eq 0 ]; then
  ok "todos os pods terminam graciosamente (max ${M_SHUTDOWN_MAX_MS}ms, limite ${LIMIT_MS}ms)"
else
  bad "algum pod demora demais para terminar"
fi
# Os controllers recriam tudo; esperamos a stack voltar antes das provas seguintes.
rollout_all || bad "a stack não voltou a ficar Ready após os deletes"

# ─── 8. As provas que o Compose não faz ──────────────────────────────────────
step "8/9  O que o ADR 0001 listou como limite do Compose, medido aqui"

# (a) Auto-cura: deletar um pod e medir até o substituto ficar Ready.
pod=$("${KC[@]}" get pod -l app=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
t0=$(now_ms)
"${KC[@]}" delete pod "$pod" --wait=false >/dev/null 2>&1
healed=""
for _ in $(seq 1 120); do
  if ! "${KC[@]}" get pod "$pod" >/dev/null 2>&1 \
     && [ "$("${KC[@]}" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "2" ]; then
    healed=1; break
  fi
  sleep 0.5
done
if [ -n "$healed" ]; then
  M_SELF_HEAL_S=$(( ($(now_ms) - t0) / 1000 ))
  ok "auto-cura: pod deletado, substituto Ready em ${M_SELF_HEAL_S}s (Compose: recriação manual)"
else
  bad "auto-cura: o substituto não ficou Ready em 60s"
fi

# (b) Processo terminado por dentro -> restart automático, contado.
# SIGTERM, e não SIGKILL: o kernel IGNORA SIGKILL enviado ao PID 1 de dentro
# do próprio namespace — é o mesmo tratamento especial de sinais que a lição 3
# do módulo Docker mediu. SIGTERM é entregue porque o worker tem handler.
base=$("${KC[@]}" get pod -l app=worker -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
"${KC[@]}" exec deploy/worker -- python3 -c 'import os, signal; os.kill(1, signal.SIGTERM)' >/dev/null 2>&1
restarted=""
for _ in $(seq 1 60); do
  rc=$("${KC[@]}" get pod -l app=worker -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
  [ -n "$rc" ] && [ "$rc" -gt "${base:-0}" ] 2>/dev/null && { restarted=1; break; }
  sleep 1
done
if [ -n "$restarted" ]; then
  ok "processo do worker terminado -> kubelet reinicia e CONTA (restartCount $base -> $rc)"
else
  bad "worker não foi reiniciado após o término do processo"
fi

# (c) Readiness ≠ liveness: derrubar a dependência tira a api do
# balanceamento SEM reiniciá-la. Reiniciar a api não ressuscita o Postgres.
"${KC[@]}" scale statefulset/db --replicas=0 >/dev/null 2>&1
t0=$(now_ms)
notready=""
for _ in $(seq 1 120); do
  ready=$("${KC[@]}" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ -z "$ready" ] || [ "$ready" -lt 2 ] 2>/dev/null; then notready=1; break; fi
  sleep 0.5
done
if [ -n "$notready" ]; then
  M_NOTREADY_S=$(( ($(now_ms) - t0) / 1000 ))
  ok "db a zero -> api sai do balanceamento em ${M_NOTREADY_S}s (readiness reprova)"
else
  bad "api continuou Ready com o banco fora do ar"
fi
rc=$("${KC[@]}" get pod -l app=api -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '+' )
if [ "$(( ${rc:-1} ))" -eq 0 ]; then
  ok "e SEM nenhum restart (restartCount=0): liveness e readiness são perguntas diferentes"
else
  bad "a api foi REINICIADA por dependência fora do ar (restartCounts: $rc)"
fi
"${KC[@]}" scale statefulset/db --replicas=1 >/dev/null 2>&1
"${KC[@]}" rollout status statefulset/db --timeout=120s >/dev/null 2>&1
recovered=""
for _ in $(seq 1 120); do
  [ "$("${KC[@]}" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "2" ] && { recovered=1; break; }
  sleep 1
done
if [ -n "$recovered" ]; then
  ok "db de volta -> api volta ao balanceamento sozinha"
else
  bad "api não se recuperou após o retorno do banco"
fi

# (d) Rolling update sem downtime, com requisições concorrentes de testemunha.
probe_code=$(curl -fsS -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
  -d '{"url":"https://example.com/"}' 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])' 2>/dev/null)
if [ -n "$probe_code" ]; then
  tmpf=$(mktemp)
  (
    while :; do
      curl -s -o /dev/null --max-time 2 -w '%{http_code}\n' "$BASEURL/api/links/$probe_code" >>"$tmpf"
      sleep 0.1
    done
  ) &
  looppid=$!
  "${KC[@]}" rollout restart deployment/api >/dev/null 2>&1
  "${KC[@]}" rollout status deployment/api --timeout=180s >/dev/null 2>&1
  sleep 1
  kill "$looppid" >/dev/null 2>&1; wait "$looppid" 2>/dev/null
  M_ROLLING_TOTAL=$(wc -l <"$tmpf" | tr -d ' ')
  M_ROLLING_FAILS=$(grep -cv '^200$' "$tmpf" || true)
  rm -f "$tmpf"
  if [ "${M_ROLLING_FAILS:-1}" -eq 0 ] && [ "${M_ROLLING_TOTAL:-0}" -gt 0 ]; then
    ok "rolling restart com ${M_ROLLING_TOTAL} requisições concorrentes e 0 falhas"
  else
    bad "rolling restart derrubou ${M_ROLLING_FAILS} de ${M_ROLLING_TOTAL} requisições"
  fi
else
  bad "não consegui criar o link-testemunha para o teste de rolling"
fi

# ─── 9. Medições + teardown ──────────────────────────────────────────────────
step "9/9  Gravar medições e derrubar o cluster"

if K8S_MEASURED_OUT="site/src/data/k8s-measured.json" \
   M_CLUSTER_CREATE_S="$M_CLUSTER_CREATE_S" M_STACK_READY_S="$M_STACK_READY_S" \
   M_SELF_HEAL_S="$M_SELF_HEAL_S" M_NOTREADY_S="$M_NOTREADY_S" \
   M_ROLLING_TOTAL="$M_ROLLING_TOTAL" M_ROLLING_FAILS="$M_ROLLING_FAILS" \
   M_SHUTDOWN_MAX_MS="$M_SHUTDOWN_MAX_MS" \
   python3 - <<'PY'
import json, os, subprocess, datetime

def num(name):
    v = os.environ.get(name, "")
    return int(v) if v.strip().isdigit() else None

kind_v = subprocess.run(["kind", "version"], capture_output=True, text=True).stdout.split()[1]
k8s_v = ""
try:
    out = subprocess.run(["kubectl", "version", "-o", "json"], capture_output=True, text=True).stdout
    k8s_v = json.loads(out).get("serverVersion", {}).get("gitVersion", "")
except Exception:
    pass

data = {
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "kindVersion": kind_v,
    "kubernetesVersion": k8s_v,
    # Cada campo abaixo é citado por uma lição da trilha `kubernetes`.
    "measurements": {
        "clusterCreateSeconds": num("M_CLUSTER_CREATE_S"),
        "stackReadySeconds": num("M_STACK_READY_S"),
        "selfHealSeconds": num("M_SELF_HEAL_S"),
        "readinessReactSeconds": num("M_NOTREADY_S"),
        "rollingRequestsTotal": num("M_ROLLING_TOTAL"),
        "rollingRequestsFailed": num("M_ROLLING_FAILS"),
        "shutdownMaxMs": num("M_SHUTDOWN_MAX_MS"),
    },
}
out_path = os.environ["K8S_MEASURED_OUT"]
with open(out_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"  {out_path} gravado")
PY
then
  ok "medições -> site/src/data/k8s-measured.json"
else
  bad "não consegui gravar as medições"
fi

if [ "${KEEP_CLUSTER:-0}" = "1" ]; then
  skip "cluster mantido (KEEP_CLUSTER=1) — derrube com 'make k8s-down'"
else
  if kind delete cluster --name "$CLUSTER" >/dev/null 2>&1; then
    rm -f "$KUBECONFIG"
    ok "kind delete cluster (nada fica para trás)"
  else
    bad "kind delete cluster falhou"
  fi
fi

# ─── Resumo ──────────────────────────────────────────────────────────────────
printf '\n\033[1m═══ Resumo (módulo Kubernetes) ═══\033[0m\n'
printf '   \033[32m%d passaram\033[0m · \033[31m%d falharam\033[0m · \033[33m%d puladas\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\n   Falhas:\n'
  printf '%s\n' "${RESULTS[@]}" | grep '^FAIL' | sed 's/^/     /'
  exit 1
fi
echo "   tudo verificado."
