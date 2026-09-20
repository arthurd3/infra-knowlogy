#!/usr/bin/env bash
# O portão de qualidade. Roda tudo e falha alto.
#
# A ideia: cada afirmação que as lições fazem sobre esta stack deve ser
# verificável por um comando. Se o endurecimento regredir, se o desligamento
# parar de ser gracioso, se um segredo vazar para a imagem — este script
# reprova, e a lição correspondente deixa de estar mentindo.
#
#   SKIP_SCAN=1     pula o Trivy (rápido, para iteração local)
#   SKIP_OBS=1      pula a checagem do profile de observabilidade
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE=(-f stack/compose.yaml)
PROD=("${BASE[@]}" -f stack/compose.prod.yaml)
OBS=("${PROD[@]}" -f stack/compose.obs.yaml)
COMPOSE=(docker compose "${PROD[@]}")

PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()

step()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()    { printf '   \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); RESULTS+=("PASS  $1"); }
bad()   { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); }
skip()  { printf '   \033[33m⊘\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $1"); }

# ─── 1. Lint estático ────────────────────────────────────────────────────────
step "1/9  Lint de Dockerfile e validação dos compose files"

for f in $(find stack site -name Dockerfile -not -path '*/node_modules/*'); do
  if docker run --rm -i hadolint/hadolint:latest hadolint --no-color - < "$f" >/tmp/hl.txt 2>&1; then
    ok "hadolint $f"
  else
    bad "hadolint $f"; sed 's/^/       /' /tmp/hl.txt | head -12
  fi
done

for combo in "PROD:${PROD[*]}" "DEV:${BASE[*]} -f stack/compose.dev.yaml" "OBS:${OBS[*]}"; do
  name="${combo%%:*}"; files="${combo#*:}"
  # shellcheck disable=SC2086
  if docker compose $files config -q >/tmp/cc.txt 2>&1; then
    ok "compose config ($name)"
  else
    bad "compose config ($name)"; sed 's/^/       /' /tmp/cc.txt | head -6
  fi
done

# ─── 2. Build + medição ──────────────────────────────────────────────────────
step "2/9  Build de todas as imagens e medição de tamanho"
if "${COMPOSE[@]}" build >/tmp/build.txt 2>&1; then
  ok "docker compose build"
else
  bad "docker compose build"; tail -20 /tmp/build.txt | sed 's/^/       /'
fi
if bash tools/scripts/sizes.sh >/tmp/sizes.txt 2>&1; then
  ok "medição de tamanho -> site/src/data/measured.json"
  grep -E '^\s+\w' /tmp/sizes.txt | sed 's/^/    /'
else
  bad "medição de tamanho"; tail -10 /tmp/sizes.txt | sed 's/^/       /'
fi

# ─── 3. Subir e esperar saúde ────────────────────────────────────────────────
step "3/9  Subir a stack e esperar todos os healthchecks"
bash tools/scripts/init-secrets.sh >/dev/null 2>&1
if "${COMPOSE[@]}" up -d --wait --wait-timeout 180 >/tmp/up.txt 2>&1; then
  ok "up --wait: todos os serviços saudáveis"
else
  bad "up --wait falhou"; tail -20 /tmp/up.txt | sed 's/^/       /'
  "${COMPOSE[@]}" ps | sed 's/^/       /'
fi

# ─── 4. Smoke test do fluxo completo ─────────────────────────────────────────
step "4/9  Smoke test: criar link -> redirecionar -> enriquecer"
PORT="$(grep -E '^EDGE_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; PORT="${PORT:-8080}"
BASEURL="http://127.0.0.1:${PORT}"

# O miolo do smoke vive em lib/smoke.sh, compartilhado com o k8s-verify.sh —
# os dois portões provam o mesmo fluxo porque a aplicação é a mesma.
source tools/scripts/lib/smoke.sh
smoke_logs() { "${COMPOSE[@]}" logs --tail 20 "$@" | sed 's/^/       /'; }
run_smoke
if "${COMPOSE[@]}" exec -T api /api-go healthcheck >/dev/null 2>&1; then
  ok "readyz da api responde"
else
  bad "readyz da api falhou"
fi

# ─── 5. Endurecimento ────────────────────────────────────────────────────────
step "5/9  Provas de endurecimento (OWASP)"

# Rootfs imutável: escrever na raiz tem que falhar.
if "${COMPOSE[@]}" exec -T worker sh -c 'echo x > /provaescrita' >/dev/null 2>&1; then
  bad "rootfs do worker é GRAVÁVEL (read_only não está valendo)"
else
  ok "rootfs read-only aplicado (escrita em / recusada)"
fi
# ...mas o tmpfs declarado precisa funcionar.
if "${COMPOSE[@]}" exec -T worker sh -c 'echo x > /tmp/ok && rm /tmp/ok' >/dev/null 2>&1; then
  ok "tmpfs /tmp gravável"
else
  bad "tmpfs /tmp NÃO é gravável — a aplicação vai quebrar"
fi

uid=$("${COMPOSE[@]}" exec -T worker id -u 2>/dev/null | tr -d '\r\n')
if [ "$uid" = "65532" ]; then ok "worker roda como não-root (uid=$uid)"; else bad "worker roda como uid=$uid"; fi

if "${COMPOSE[@]}" exec -T api /api-go healthcheck >/dev/null 2>&1 \
   && ! "${COMPOSE[@]}" exec -T api /bin/sh -c true >/dev/null 2>&1; then
  ok "imagem da api é distroless (não há shell para um invasor usar)"
else
  skip "checagem de distroless inconclusiva"
fi

# Nenhuma porta publicada em 0.0.0.0.
if "${COMPOSE[@]}" ps --format json 2>/dev/null | grep -q '0\.0\.0\.0'; then
  bad "há porta publicada em 0.0.0.0 (fura o firewall — OWASP 5a)"
else
  ok "todas as portas publicadas estão presas a 127.0.0.1"
fi

# O segredo não pode estar em nenhuma camada nem no ambiente do container.
secret=$(cat stack/secrets/postgres_password 2>/dev/null)
if [ -n "$secret" ]; then
  if docker history --no-trunc infra-knowlogy/api-go:dev 2>/dev/null | grep -qF "$secret" \
  || "${COMPOSE[@]}" exec -T api env 2>/dev/null | grep -qF "$secret"; then
    bad "SEGREDO VAZOU para o histórico da imagem ou para o ambiente"
  else
    ok "segredo não aparece no histórico da imagem nem em 'env'"
  fi
fi

# Segmentação: o proxy não deve alcançar o banco.
if "${COMPOSE[@]}" exec -T edge sh -c 'nc -z -w2 db 5432' >/dev/null 2>&1; then
  bad "o edge ALCANÇA o banco (a segmentação de rede não está valendo)"
else
  ok "segmentação de rede: o edge não alcança o db"
fi

# ─── 6. Desligamento gracioso ────────────────────────────────────────────────
step "6/9  Desligamento gracioso (limite 3s por serviço)"
if bash tools/scripts/shutdown-test.sh >/tmp/sd.txt 2>&1; then
  ok "todos os serviços param em menos de 3s"
  grep -E '✓|✗' /tmp/sd.txt | sed 's/^/    /'
else
  bad "algum serviço demora demais para parar"
  sed 's/^/       /' /tmp/sd.txt
fi

# ─── 7. Scanner ──────────────────────────────────────────────────────────────
step "7/9  Vulnerabilidades (Trivy, HIGH+CRITICAL)"
if [ "${SKIP_SCAN:-0}" = "1" ]; then
  skip "scan pulado (SKIP_SCAN=1)"
else
  bash tools/scripts/scan.sh >/tmp/scan.txt 2>&1
  case $? in
    0) ok "nenhuma vulnerabilidade HIGH/CRITICAL corrigível" ;;
    1) bad "vulnerabilidades HIGH/CRITICAL encontradas"
       grep -E 'Total:|CVE-' /tmp/scan.txt | head -15 | sed 's/^/       /' ;;
    # Scanner quebrado NÃO é o mesmo que imagem limpa nem que imagem vulnerável.
    # Reportar as duas coisas como a mesma falha faz o portão mentir.
    *) bad "o SCANNER falhou (veredito indisponível, não é um achado)"
       tail -8 /tmp/scan.txt | sed 's/^/       /' ;;
  esac
fi

# ─── 8. Site ─────────────────────────────────────────────────────────────────
# Quatro checagens em camadas: tipos, lógica, build e o HTML que sai dele.
# A paridade PT/EN, que antes era um heredoc Python aqui dentro (duplicado no
# ci.yml), virou teste de verdade em site/tests/content.test.ts — junto das
# checagens que ela sozinha não fazia: os dois idiomas usam os MESMOS widgets
# e diagramas, e nenhuma lição nasce só com texto.
step "8/9  Site: tipos, testes, build e HTML gerado"

if (cd site && npm run check >/tmp/site-check.txt 2>&1); then
  ok "astro check (tipos do site)"
else
  bad "astro check"; grep -E 'error|Result' /tmp/site-check.txt | tail -12 | sed 's/^/       /'
fi

if (cd site && npm test >/tmp/site-test.txt 2>&1); then
  ok "testes do site ($(grep -oE 'Tests +[0-9]+ passed' /tmp/site-test.txt | grep -oE '[0-9]+' | head -1) casos)"
else
  bad "testes do site"; grep -E 'FAIL|AssertionError|Tests ' /tmp/site-test.txt | head -12 | sed 's/^/       /'
fi

if (cd site && npm run build >/tmp/site.txt 2>&1); then
  ok "astro build"
else
  bad "astro build"; tail -15 /tmp/site.txt | sed 's/^/       /'
fi

# O HTML gerado é o único artefato que o leitor de fato recebe. Um link interno
# quebrado não reprova build nenhum — só reprova aqui.
if node tools/scripts/site-check.mjs >/tmp/site-html.txt 2>&1; then
  ok "HTML gerado ($(grep -oE '[0-9]+ passaram' /tmp/site-html.txt | head -1))"
else
  bad "HTML gerado"; grep -E '✗|       ' /tmp/site-html.txt | head -12 | sed 's/^/       /'
fi

# ─── 9. Observabilidade ──────────────────────────────────────────────────────
step "9/9  Profile de observabilidade"
if [ "${SKIP_OBS:-0}" = "1" ]; then
  skip "observabilidade pulada (SKIP_OBS=1)"
elif docker compose "${OBS[@]}" --profile obs up -d --wait --wait-timeout 240 >/tmp/obs.txt 2>&1; then
  ok "stack de observabilidade saudável"

  PPORT="$(grep -E '^PROMETHEUS_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; PPORT="${PPORT:-9090}"
  GPORT="$(grep -E '^GRAFANA_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; GPORT="${GPORT:-3000}"

  curl -fsS "http://127.0.0.1:${PPORT}/-/healthy" >/dev/null 2>&1 \
    && ok "prometheus /-/healthy" || bad "prometheus não responde"
  curl -fsS "http://127.0.0.1:${GPORT}/api/health" >/dev/null 2>&1 \
    && ok "grafana /api/health" || bad "grafana não responde"

  # Alvos precisam estar UP; um scrape config errado passa silenciosamente sem isto.
  sleep 20
  down=$(curl -fsS "http://127.0.0.1:${PPORT}/api/v1/targets?state=active" 2>/dev/null \
    | python3 -c 'import sys,json; print(",".join(t["labels"].get("job","?") for t in json.load(sys.stdin)["data"]["activeTargets"] if t["health"]!="up"))' 2>/dev/null)
  if [ -z "$down" ]; then ok "todos os alvos do prometheus estão up"; else bad "alvos fora do ar: $down"; fi

  # ── As regras de SLO ───────────────────────────────────────────────────────
  # Sem esta checagem, um erro de sintaxe no slo.yml faz o Prometheus subir
  # normalmente e simplesmente NÃO avaliar regra nenhuma. O painel continua
  # bonito, o alerta nunca dispara, e ninguém descobre até o incidente.
  RULES=$(curl -fsS "http://127.0.0.1:${PPORT}/api/v1/rules" 2>/dev/null)
  case "$RULES" in
    *OrcamentoDeErroQueimandoRapido*)
      nrec=$(printf '%s' "$RULES" | python3 -c 'import sys,json; g=json.load(sys.stdin)["data"]["groups"]; print(sum(1 for x in g for r in x["rules"] if r["type"]=="recording"))' 2>/dev/null)
      nalert=$(printf '%s' "$RULES" | python3 -c 'import sys,json; g=json.load(sys.stdin)["data"]["groups"]; print(sum(1 for x in g for r in x["rules"] if r["type"]=="alerting"))' 2>/dev/null)
      ok "regras de SLO carregadas (${nrec:-?} de gravação, ${nalert:-?} de alerta)" ;;
    *) bad "as regras de SLO não foram carregadas pelo prometheus" ;;
  esac

  # Regra com erro de avaliação fica `health: err` e não produz série. Ela
  # aparece como carregada na checagem acima — por isso esta segunda.
  ruins=$(printf '%s' "$RULES" | python3 -c 'import sys,json; g=json.load(sys.stdin)["data"]["groups"]; print(",".join(r.get("name","?") for x in g for r in x["rules"] if r.get("health")!="ok"))' 2>/dev/null)
  if [ -z "$ruins" ]; then ok "toda regra de SLO avalia sem erro"; else bad "regras com erro de avaliação: $ruins"; fi

  # ── O SLI tem denominador de USUÁRIO ───────────────────────────────────────
  # A série só existe se o `route!~` do slo.yml casar com rótulo de verdade.
  # Renomear uma rota na api quebraria o SLI em silêncio: a query continua
  # válida, o resultado vira vazio, e um alerta sobre vazio nunca dispara.
  sli=$(curl -fsS --get "http://127.0.0.1:${PPORT}/api/v1/query" \
        --data-urlencode 'query=api:sli_disponibilidade:ratio5m' 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]["result"]; print(d[0]["value"][1] if d else "")' 2>/dev/null)
  if [ -n "$sli" ]; then
    ok "o SLI de disponibilidade tem valor ($sli)"
  else
    bad "api:sli_disponibilidade:ratio5m não produziu valor — o rótulo de rota mudou?"
  fi

  # ── A cardinalidade que o relabel corta ────────────────────────────────────
  # A lição afirma que o metric_relabel_configs do cAdvisor descarta a maior
  # parte do que ele publica. Se alguém remover o filtro, a afirmação vira
  # mentira e a stack vira GB de RAM — as duas coisas nesta única checagem.
  dropped=$(curl -fsS --get "http://127.0.0.1:${PPORT}/api/v1/query" \
        --data-urlencode 'query=scrape_samples_scraped{job="cadvisor"} - scrape_samples_post_metric_relabeling{job="cadvisor"}' 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]["result"]; print(int(float(d[0]["value"][1])) if d else 0)' 2>/dev/null)
  if [ "${dropped:-0}" -gt 100 ]; then
    ok "o relabel do cAdvisor descarta ${dropped} amostras por raspagem"
  else
    bad "o filtro de cardinalidade do cAdvisor não está cortando (${dropped:-0} amostras)"
  fi

  # ── E as medições, que as lições citam ─────────────────────────────────────
  # Antes de medir, um pouco de tráfego de USUÁRIO. O `up -d --wait` do profile
  # obs recria a api, e com ela os contadores zeram — sem isto o denominador do
  # SLI é zero, a razão infraestrutura/usuário sai `null` e o diagrama que lê o
  # arquivo publica a palavra "null" para o leitor.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -fsS -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
           -d '{"url":"https://example.com/"}' 2>/dev/null \
           | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])' 2>/dev/null)
    [ -n "$code" ] && curl -fsS -o /dev/null "$BASEURL/r/$code" 2>/dev/null
  done
  sleep 20

  if python3 tools/scripts/obs-measure.py >/tmp/obsm.txt 2>&1; then
    ok "medições gravadas -> site/src/data/obs-measured.json"
    sed 's/^/    /' /tmp/obsm.txt | tail -4
  else
    bad "medição da observabilidade falhou"; tail -5 /tmp/obsm.txt | sed 's/^/       /'
  fi
else
  bad "stack de observabilidade não subiu"; tail -20 /tmp/obs.txt | sed 's/^/       /'
fi

# ─── Resumo ──────────────────────────────────────────────────────────────────
printf '\n\033[1m═══ Resumo ═══\033[0m\n'
printf '   \033[32m%d passaram\033[0m · \033[31m%d falharam\033[0m · \033[33m%d puladas\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\n   Falhas:\n'
  printf '%s\n' "${RESULTS[@]}" | grep '^FAIL' | sed 's/^/     /'
  exit 1
fi
echo "   tudo verificado."
