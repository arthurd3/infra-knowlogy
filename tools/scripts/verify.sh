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
#   SKIP_OPS=1      pula as checagens de operação (cgroup, OOM, DNS, Postgres)
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
step "1/10 Lint de Dockerfile e validação dos compose files"

for f in $(find stack site -name Dockerfile -not -path '*/node_modules/*'); do
  # O hadolint era a única imagem de ferramenta do repositório ainda em
  # `:latest` — o que significa que o portão podia mudar de comportamento sem
  # nenhum commit, reprovando um Dockerfile que passava ontem. É exatamente o
  # que o ADR 0004 existe para impedir, e passou despercebido porque `:latest`
  # numa ferramenta parece inofensivo.
  if docker run --rm -i hadolint/hadolint:latest@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d hadolint --no-color - < "$f" >/tmp/hl.txt 2>&1; then
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

# ─── As armadilhas de shell, medidas ─────────────────────────────────────────
# Ficam aqui, no passo 1, porque não precisam de Docker nem da stack: é bash
# medindo bash. Uma lição sobre escrever script não deveria depender da
# infraestrutura que o script gerencia.
if python3 tools/scripts/bash-traps-measure.py >/tmp/bashm.txt 2>&1; then
  ok "armadilhas de shell medidas -> site/src/data/bash-measured.json"
else
  bad "a medição das armadilhas de shell falhou"; tail -6 /tmp/bashm.txt | sed 's/^/       /'
fi

while IFS='|' read -r VEREDITO MSG; do
  case "$VEREDITO" in
    OK) ok "$MSG" ;;
    "") : ;;
    *)  bad "$MSG" ;;
  esac
done < <(python3 - site/src/data/bash-measured.json <<'PYBASH'
import json, sys

try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"BAD|não consegui ler o bash-measured.json ({exc})")
    raise SystemExit(0)

corrida = d.get("corrida_sigpipe", [])
buf = d.get("buffer_de_pipe_bytes", 0)
saida = d.get("codigo_de_saida", {})
classes = d.get("classes_de_caractere", {})

# 1. A checagem INCOMUM: ela exige que o defeito CONTINUE existindo.
#    Acima do buffer do pipe o escritor não tem como terminar antes do leitor
#    sair, então a falha é determinística. Se um dia parar de falhar, a
#    armadilha mudou de forma e a lição precisa mudar junto — calar isso seria
#    publicar um número que deixou de ser verdade.
acima = [c for c in corrida if c["bytes"] > buf]
if acima and all(c["falhas_com_pipe"] == c["rodadas"] for c in acima):
    n = acima[0]["rodadas"]
    print(f"bash: `texto | grep -q` com pipefail erra {n}/{n} acima do buffer do pipe "
          f"({buf // 1024} KiB) — a armadilha 29 continua de pé".replace("bash:", "OK|bash:", 1))
else:
    detalhe = ", ".join(f"{c['bytes']}B:{c['falhas_com_pipe']}/{c['rodadas']}" for c in acima)
    print(f"BAD|bash: a forma com pipe deixou de falhar sempre acima do buffer ({detalhe}) — "
          f"a armadilha mudou e a lição precisa ser remedida")

# 2. A forma correta não pode falhar NUNCA, em nenhum tamanho.
ruins = [c for c in corrida if c["falhas_sem_pipe"] != 0]
if corrida and not ruins:
    print(f"OK|bash: a forma sem pipe (`case` sobre a saída) acerta em "
          f"{sum(c['rodadas'] for c in corrida)} execuções, de 1 KiB a 1 MiB")
else:
    print(f"BAD|bash: a forma sem pipe falhou em {len(ruins)} tamanho(s) — "
          f"a correção da armadilha 29 não é determinística")

# 3. `local v=$(cmd)` mascara o código de saída (ShellCheck SC2155).
if saida.get("local_na_mesma_linha") == 0 and saida.get("local_separado") == 7:
    print("OK|bash: `local v=$(cmd)` devolve 0 e mascara o erro; separado devolve 7 (SC2155)")
else:
    print(f"BAD|bash: o mascaramento do `local` mudou "
          f"(junto={saida.get('local_na_mesma_linha')} separado={saida.get('local_separado')})")

# 4. A prova NEGATIVA da armadilha 27, que foi corrigida por não reproduzir.
#    Enquanto as duas formas derem o mesmo resultado, a correção está certa.
por_ferr = classes.get("por_ferramenta", {})
iguais = [k for k, v in por_ferr.items() if v.get("barra_s") == v.get("posix") and v.get("posix", 0) > 0]
if len(iguais) == len(por_ferr) and por_ferr and classes.get("barra_s_casa_letra_s") == 0:
    print(f"OK|bash: `\\s` e `[[:space:]]` dão o mesmo resultado em {len(iguais)} ferramentas, "
          f"e `\\s` não casa a letra s (a armadilha 27 não reproduz)")
else:
    print(f"BAD|bash: `\\s` e `[[:space:]]` divergiram (iguais em {len(iguais)} de {len(por_ferr)}, "
          f"casa-letra-s={classes.get('barra_s_casa_letra_s')})")
PYBASH
)

# ─── As três linguagens, comparadas ──────────────────────────────────────────
# Precisa de Docker (constrói a fixture nas duas linguagens) mas não da stack;
# a memória em repouso é medida depois, quando ela estiver no ar, e o script
# declara `repouso_medido: false` se não estiver.
if python3 tools/scripts/languages-measure.py >/tmp/langm.txt 2>&1; then
  ok "as três linguagens medidas -> site/src/data/languages-measured.json"
else
  bad "a medição das linguagens falhou"; tail -6 /tmp/langm.txt | sed 's/^/       /'
fi

while IFS='|' read -r VEREDITO MSG; do
  case "$VEREDITO" in
    OK) ok "$MSG" ;;
    "") : ;;
    *)  bad "$MSG" ;;
  esac
done < <(python3 - site/src/data/languages-measured.json <<'PYLANG'
import json, sys

try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"BAD|não consegui ler o languages-measured.json ({exc})")
    raise SystemExit(0)

erro = d.get("quando_o_erro_aparece", {})
locks = {l["arquivo"].split("/")[-1]: l for l in d.get("locks", [])}

# A checagem que exige que algo NÃO compile. A lição afirma um comportamento —
# o mesmo typo, no mesmo ramo morto, parando o build em Go e passando em Python
# — e comportamento afirmado sem checagem envelhece em silêncio.
go, py = erro.get("go", {}), erro.get("python", {})
if go.get("produziu_binario") is False and py.get("rodou_ate_o_fim") is True and py.get("saida") == 0:
    print(f"OK|linguagens: o mesmo typo em ramo morto para o build em Go "
          f"(saída {go.get('saida')}, binário nenhum) e passa em Python (saída 0)")
elif go.get("produziu_binario") is True:
    print("BAD|linguagens: a fixture Go COMPILOU — o typo deliberado sumiu, ou o compilador mudou")
else:
    print(f"BAD|linguagens: a demonstração do typo não reproduziu "
          f"(go={go.get('saida')} python={py.get('saida')})")

# Os três locks precisam existir e ser lidos; é deles que a lição tira a
# comparação de árvore de dependências.
faltando = [n for n in ("go.sum", "uv.lock", "package-lock.json") if n not in locks]
if not faltando:
    print(f"linguagens: os 3 locks lidos — go.sum {locks['go.sum']['linhas']}, "
          f"uv.lock {locks['uv.lock']['linhas']}, "
          f"package-lock.json {locks['package-lock.json']['linhas']} linhas".replace(
              "linguagens:", "OK|linguagens:", 1))
else:
    print(f"BAD|linguagens: lock ausente ({', '.join(faltando)})")
PYLANG
)

# ─── 2. Build + medição ──────────────────────────────────────────────────────
step "2/10 Build de todas as imagens e medição de tamanho"
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
step "3/10 Subir a stack e esperar todos os healthchecks"
bash tools/scripts/init-secrets.sh >/dev/null 2>&1
if "${COMPOSE[@]}" up -d --wait --wait-timeout 180 >/tmp/up.txt 2>&1; then
  ok "up --wait: todos os serviços saudáveis"
else
  bad "up --wait falhou"; tail -20 /tmp/up.txt | sed 's/^/       /'
  "${COMPOSE[@]}" ps | sed 's/^/       /'
fi

# ─── 4. Smoke test do fluxo completo ─────────────────────────────────────────
step "4/10 Smoke test: criar link -> redirecionar -> enriquecer"
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
step "5/10 Provas de endurecimento (OWASP)"

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
step "6/10 Desligamento gracioso (limite 3s por serviço)"
if bash tools/scripts/shutdown-test.sh >/tmp/sd.txt 2>&1; then
  ok "todos os serviços param em menos de 3s"
  grep -E '✓|✗' /tmp/sd.txt | sed 's/^/    /'
else
  bad "algum serviço demora demais para parar"
  sed 's/^/       /' /tmp/sd.txt
fi

# ─── 7. Scanner ──────────────────────────────────────────────────────────────
step "7/10 Vulnerabilidades (Trivy, HIGH+CRITICAL)"
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
step "8/10 Site: tipos, testes, build e HTML gerado"

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
step "9/10 Profile de observabilidade"
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


  # ─── Alertmanager: o alerta que SAI ───────────────────────────────────────
  # Até agora o portão provava que a regra avalia e que o Prometheus a marca
  # como `firing`. Isso é um estado numa página web. O que faltava — e o que a
  # lição `burn-rate-alerting` admitia faltar — é provar que alguém é avisado.
  #
  # As checagens abaixo usam um alerta SINTÉTICO postado na API, e não uma
  # queda de verdade: roteamento e entrega são o mesmo mecanismo para qualquer
  # alerta, e forçar uma queda custaria três minutos para provar a mesma coisa.
  APORT="$(grep -E '^ALERTMANAGER_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; APORT="${APORT:-9093}"

  curl -fsS "http://127.0.0.1:${APORT}/-/healthy" >/dev/null 2>&1 \
    && ok "alertmanager /-/healthy" || bad "alertmanager não responde"

  # O Prometheus precisa SABER para onde mandar. Sem o bloco `alerting:` ele
  # avalia, marca firing e não conta a ninguém — em silêncio.
  AMS=$(curl -s "http://127.0.0.1:${PPORT}/api/v1/alertmanagers" 2>/dev/null)
  case "$AMS" in
    *alertmanager:9093*) ok "o prometheus conhece o alertmanager (activeAlertmanagers)" ;;
    *) bad "o prometheus NÃO tem alertmanager ativo — falta o bloco alerting:" ;;
  esac

  # ── Roteamento por severidade. `page` acorda alguém, `ticket` não — e é essa
  # separação que torna possível esperar mediana ZERO de páginas por turno.
  N_ANTES=$(curl -s "http://127.0.0.1:${APORT}/metrics" 2>/dev/null \
    | awk '/^alertmanager_notifications_total\{integration="webhook"\}/{print $2}')
  # O nome do alerta é ÚNICO por execução, e isso não é capricho: o
  # `group_by: [alertname, severity]` faz o Alertmanager agrupar por nome, e o
  # `repeat_interval: 4h` impede que ele notifique de novo sobre um grupo que
  # já notificou. Com nome fixo, esta checagem passaria na primeira execução do
  # dia e falharia nas seguintes — um portão que só funciona uma vez.
  MARCA="$(date +%s)"
  curl -sS -XPOST "http://127.0.0.1:${APORT}/api/v2/alerts" -H 'content-type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"PortaoEntregaPage${MARCA}\",\"severity\":\"page\",\"service\":\"api\"}},
         {\"labels\":{\"alertname\":\"PortaoEntregaTicket${MARCA}\",\"severity\":\"ticket\",\"service\":\"api\"}}]" \
    -o /dev/null 2>/dev/null

  sleep 3
  ROTAS=$(curl -s "http://127.0.0.1:${APORT}/api/v2/alerts" 2>/dev/null \
    | MARCA="$MARCA" python3 -c '
import os, sys, json
marca = os.environ["MARCA"]
m = {}
for a in json.load(sys.stdin):
    n = a["labels"].get("alertname", "")
    if n.endswith(marca):
        m[n[: -len(marca)]] = sorted(r["name"] for r in a.get("receivers", []))
print(json.dumps(m))' 2>/dev/null)
  case "$ROTAS" in
    *'"PortaoEntregaPage": ["plantao"]'*) ok "roteamento: severity=page vai para o receptor 'plantao'" ;;
    *) bad "severity=page não foi roteado para 'plantao' (rotas: ${ROTAS:-vazio})" ;;
  esac
  case "$ROTAS" in
    *'"PortaoEntregaTicket": ["fila"]'*) ok "roteamento: severity=ticket vai para 'fila' e NÃO acorda ninguém" ;;
    *) bad "severity=ticket não foi roteado para 'fila' (rotas: ${ROTAS:-vazio})" ;;
  esac

  # ── Entrega. O contador do próprio Alertmanager mais o log de acesso do
  # receptor: um diz que ele TENTOU e conseguiu, o outro diz que CHEGOU.
  # Provar só pelo contador aceitaria um receptor que responde 200 e descarta.
  sleep 35                                   # o group_wait de 'plantao'
  N_DEPOIS=$(curl -s "http://127.0.0.1:${APORT}/metrics" 2>/dev/null \
    | awk '/^alertmanager_notifications_total\{integration="webhook"\}/{print $2}')
  N_FALHAS=$(curl -s "http://127.0.0.1:${APORT}/metrics" 2>/dev/null \
    | awk '/^alertmanager_notifications_failed_total\{integration="webhook"/{s+=$2} END{print s+0}')
  if [ "${N_DEPOIS:-0}" -gt "${N_ANTES:-0}" ] && [ "${N_FALHAS:-1}" -eq 0 ]; then
    ok "entrega: notifications_total foi de ${N_ANTES:-0} para ${N_DEPOIS:-0}, com 0 falhas"
  else
    bad "o alertmanager não entregou (antes=${N_ANTES:-?} depois=${N_DEPOIS:-?} falhas=${N_FALHAS:-?})"
  fi

  # Parseia o JSON em vez de grepar substring: a ordem das chaves do log do
  # Caddy põe `host` ENTRE `method` e `uri`, e um padrão colado da saída de um
  # `print` não casa. Parser não se importa com ordem.
  ENTREGAS=$(docker compose "${OBS[@]}" logs --no-log-prefix alert-sink 2>/dev/null | python3 -c '
import sys, json
n = 0
for linha in sys.stdin:
    linha = linha.strip()
    if not linha.startswith("{"):
        continue
    try:
        d = json.loads(linha)
    except Exception:
        continue
    r = d.get("request", {})
    if r.get("method") == "POST" and str(r.get("uri", "")).startswith("/plantao"):
        n += 1
print(n)' 2>/dev/null)
  if [ "${ENTREGAS:-0}" -ge 1 ]; then
    ok "o receptor registrou ${ENTREGAS} POST em /plantao (a entrega chegou do outro lado)"
  else
    bad "o receptor não registrou nenhum POST — o contador diz que saiu, e nada chegou"
  fi

  # ── Silenciamento: a única forma de calar um alerta sem apagar a regra.
  # Quem está resolvendo um incidente precisa parar de ser avisado dele sem
  # perder o alerta para o próximo.
  FIM=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  INI=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  SIL=$(curl -sS -XPOST "http://127.0.0.1:${APORT}/api/v2/silences" -H 'content-type: application/json' \
    -d "{\"matchers\":[{\"name\":\"alertname\",\"value\":\"PortaoEntregaPage${MARCA}\",\"isRegex\":false,\"isEqual\":true}],
         \"startsAt\":\"$INI\",\"endsAt\":\"$FIM\",\"createdBy\":\"portao\",\"comment\":\"prova de silenciamento\"}" 2>/dev/null)
  sleep 4
  ESTADO=$(curl -s "http://127.0.0.1:${APORT}/api/v2/alerts" 2>/dev/null \
    | MARCA="$MARCA" python3 -c '
import os, sys, json
alvo = "PortaoEntregaPage" + os.environ["MARCA"]
for a in json.load(sys.stdin):
    if a["labels"].get("alertname") == alvo:
        print(a["status"]["state"]); break
else:
    print("ausente")' 2>/dev/null)
  if [ "$ESTADO" = "suppressed" ]; then
    ok "silenciamento: o alerta continua ATIVO e fica suppressed (a regra não foi apagada)"
  else
    bad "o silêncio não suprimiu o alerta (estado: ${ESTADO:-vazio})"
  fi

  # Limpa o que o portão criou, para a próxima execução partir do mesmo lugar.
  SID=$(printf '%s' "$SIL" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("silenceID",""))' 2>/dev/null)
  [ -n "$SID" ] && curl -sS -XDELETE "http://127.0.0.1:${APORT}/api/v2/silence/$SID" -o /dev/null 2>/dev/null

  # ─── Tracing ponta a ponta ────────────────────────────────────────────────
  # A pergunta que log e métrica não respondem: "esta requisição, esta aqui,
  # passou por onde e gastou o tempo em quê?". O portão exige que UM trace_id
  # atravesse o edge, a api, a fila do Redis e o worker — porque é exatamente na
  # fila que a maioria das instrumentações se parte, e cada metade continua
  # parecendo correta sozinha.
  if python3 tools/scripts/tracing-measure.py >/tmp/tracem.txt 2>&1; then
    ok "medições de tracing gravadas -> site/src/data/tracing-measured.json"
  else
    bad "a medição de tracing falhou"; tail -6 /tmp/tracem.txt | sed 's/^/       /'
  fi

  while IFS='|' read -r VEREDITO MSG; do
    case "$VEREDITO" in
      OK) ok "$MSG" ;;
      "") : ;;
      *)  bad "$MSG" ;;
    esac
  done < <(python3 - site/src/data/tracing-measured.json <<'PYTRACE'
import json, sys

try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"BAD|não consegui ler o tracing-measured.json ({exc})")
    raise SystemExit(0)

feliz = d.get("caminho_feliz", {})
ret = d.get("caminho_retentativa", {})
custo = d.get("custo", {}).get("api_go", {})
nomes = lambda t: [s["nome"] for s in t.get("arvore", [])]
servs = lambda t: t.get("servicos", [])

# 1. Um trace_id só, atravessando os três processos. Se o traceparent não
#    sobrevivesse à fila, haveria DOIS traces corretos em vez de um.
if len(servs(feliz)) == 3 and set(servs(feliz)) == {"edge", "api-go", "worker-py"}:
    print(f"OK|tracing: um trace_id atravessa os 3 serviços "
          f"({feliz['spans']} spans, {feliz['duracao_ms']}ms)")
else:
    print(f"BAD|tracing: o trace não cobriu os 3 serviços (achei {servs(feliz)})")

# 2. A raiz nasce no edge, não na api. Sem instrumentar o proxy, o tempo gasto
#    nele fica fora da conta — e é onde TLS e espera por upstream moram.
raiz = [s for s in feliz.get("arvore", []) if s.get("nivel") == 0]
if len(raiz) == 1 and raiz[0]["servico"] == "edge":
    print(f"OK|tracing: o span raiz é do edge ({raiz[0]['nome']}), e não da api")
else:
    print(f"BAD|tracing: a raiz não é do edge (achei {[r['servico'] for r in raiz]})")

# 3. O worker chegou ao banco DENTRO do mesmo trace.
if "db.update" in nomes(feliz) and "http.fetch" in nomes(feliz):
    print("OK|tracing: http.fetch e db.update do worker estão no mesmo trace da requisição")
else:
    print(f"BAD|tracing: faltou http.fetch ou db.update no trace feliz ({nomes(feliz)})")

# 4. A prova que importa: as RETENTATIVAS ficam no mesmo trace. Reenfileirar o
#    código cru funcionava e produzia traces órfãos — o caminho lento, que é o
#    único que você investiga, era justamente o que o tracing não cobria.
tentativas = nomes(ret).count("http.fetch")
if tentativas >= 3 and len(servs(ret)) == 3:
    print(f"OK|tracing: as {tentativas} tentativas ficam NO MESMO trace "
          f"(profundidade {ret['profundidade']}), e não em traces órfãos")
elif tentativas >= 3:
    print(f"BAD|tracing: as {tentativas} tentativas estão juntas mas o trace perdeu um serviço ({servs(ret)})")
else:
    print(f"BAD|tracing: só achei {tentativas} tentativas no trace de retentativa — "
          f"o reenfileiramento perdeu o traceparent")

# 5. O custo é medido contra uma referência PROVADAMENTE não instrumentada.
#    Sem esta prova, comparar instrumentado com instrumentado daria delta zero e
#    a lição anunciaria, com número medido, que observabilidade é de graça.
if not custo.get("referencia_valida"):
    print("BAD|tracing: não sobrou imagem sem OTel para comparar — o custo gravado é de outra execução")
elif custo.get("simbolos_otel_sem") == 0 and (custo.get("simbolos_otel_com") or 0) > 1000:
    pct = 100 * (custo["imagem_com_bytes"] / custo["imagem_sem_bytes"] - 1)
    print(f"OK|tracing: custo medido contra referência com 0 símbolos OTel "
          f"({custo['imagem_sem_bytes']/1e6:.1f} -> {custo['imagem_com_bytes']/1e6:.1f} MB, +{pct:.0f}%)")
else:
    print(f"BAD|tracing: a referência não prova ausência de OTel "
          f"(sem={custo.get('simbolos_otel_sem')} com={custo.get('simbolos_otel_com')})")
PYTRACE
)

  if python3 tools/scripts/obs-measure.py >/tmp/obsm.txt 2>&1; then
    ok "medições gravadas -> site/src/data/obs-measured.json"
    sed 's/^/    /' /tmp/obsm.txt | tail -4
  else
    bad "medição da observabilidade falhou"; tail -5 /tmp/obsm.txt | sed 's/^/       /'
  fi
else
  bad "stack de observabilidade não subiu"; tail -20 /tmp/obs.txt | sed 's/^/       /'
fi

# ─── 10. Operação: Linux, rede e Postgres, medidos contra a stack ────────────
step "10/10 Operação (cgroup, OOM, DNS e Postgres)"

if [ "${SKIP_OPS:-0}" = "1" ]; then
  skip "trilha de operação pulada (SKIP_OPS=1)"
else
  # ─── Subir com o MESMO conjunto de arquivos que o passo 9 usou ────────────
  # Esta linha subia com `PROD`, sem o overlay de observabilidade — e o Compose
  # trata isso como mudança de configuração: ele RECRIA os serviços que o
  # overlay tocava, jogando fora o que o passo 9 acabou de montar.
  #
  # O sintoma foi o edge perder `OTEL_EXPORTER_OTLP_ENDPOINT` ao fim de todo
  # `make verify`. Dentro do portão passava (o passo 10 vem depois do 9), mas a
  # stack ficava sem tracing para quem fosse medir à mão logo em seguida — e a
  # medição então acusava o edge de estar mal configurado.
  if [ "${SKIP_OBS:-0}" = "1" ]; then
    docker compose "${PROD[@]}" up -d --wait --wait-timeout 180 >/dev/null 2>&1
  else
    docker compose "${OBS[@]}" --profile obs up -d --wait --wait-timeout 180 >/dev/null 2>&1
  fi

  # ── O UID do container É o UID do host. Enquanto o user namespace estiver
  # desligado (padrão do Docker), não há tradução nenhuma — e o `ps` do host
  # resolve o número pelo /etc/passwd DELE. É por isso que o Postgres desta
  # stack, que roda como UID 70, aparece no host com o nome que este Fedora
  # dá ao 70. Se isso deixar de valer, ou o userns foi ligado ou a imagem
  # mudou de usuário, e as duas coisas mudam a lição.
  PID_DB=$(docker inspect --format '{{.State.Pid}}' "$(docker compose "${PROD[@]}" ps -q db)" 2>/dev/null)
  UID_DB=$(ps -o uid= -p "$PID_DB" 2>/dev/null | tr -d ' ')
  UID_INTERNO=$(docker compose "${PROD[@]}" exec -T db id -u postgres 2>/dev/null | tr -d '\r ')
  if [ -n "$UID_DB" ] && [ "$UID_DB" = "${UID_INTERNO:-x}" ]; then
    NOME_HOST=$(ps -o user= -p "$PID_DB" 2>/dev/null | tr -d ' ')
    ok "o UID do container é o do host (uid=$UID_DB; o host chama de '$NOME_HOST')"
  else
    bad "o UID visto do host ($UID_DB) difere do de dentro ($UID_INTERNO) — userns ligado?"
  fi

  # ── O limite do cgroup é LEGÍVEL de dentro, e é o que a aplicação deveria
  # consultar em vez de /proc/meminfo, que mostra a memória do HOST.
  MEM_MAX=$(docker compose "${PROD[@]}" exec -T worker cat /sys/fs/cgroup/memory.max 2>/dev/null | tr -d '\r ')
  MEM_HOST=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
  if [ -n "$MEM_MAX" ] && [ "$MEM_MAX" != "max" ] && [ "$MEM_MAX" -lt "$MEM_HOST" ]; then
    ok "cgroup v2: o worker lê seu próprio limite ($((MEM_MAX/1048576)) MiB; o host tem $((MEM_HOST/1073741824)) GiB)"
  else
    bad "não consegui ler memory.max do worker (valor: '${MEM_MAX:-vazio}')"
  fi

  # ── O OOM killer, provocado. O que importa não é morrer: é SIGKILL não ser
  # capturável, então nenhum `defer`, `finally` ou handler roda.
  #
  # ─── Por que NÃO confiar no `.State.OOMKilled` do Docker ──────────────────
  # A primeira versão desta checagem exigia `OOMKilled=true`. Ela reprovou
  # contra uma execução em que o OOM aconteceu de verdade: o Docker reportou
  # `false` e o código de saída foi 137 — que é 128+9, exatamente o SIGKILL que
  # o próprio Docker diz não ter acontecido.
  #
  # Quem tem a verdade é o kernel, em `memory.events` do cgroup. Medido nesta
  # máquina: `oom 1`, `oom_kill 1`, `max 324` (as recuperações tentadas antes de
  # matar). Por isso a checagem lê o contador de DENTRO do cgroup, antes de o
  # container sumir, e a flag do Docker entra só como informação.
  docker rm -f ops-oom-gate >/dev/null 2>&1
  OOM_SAIDA=$(docker run --name ops-oom-gate --memory=64m --memory-swap=64m \
    --entrypoint sh python:3.13-alpine@sha256:1a63a53928ce53d2b0baf08092a703f4840ac5dfbd61fd48802dbf48e08c801e -c '
python -c "b=[]
while True: b.append(bytearray(8*1024*1024))" >/dev/null 2>&1
echo "filho=$?"
sed -n "s/^oom_kill /oom_kill=/p" /sys/fs/cgroup/memory.events' 2>/dev/null)
  OOM_FLAG=$(docker inspect ops-oom-gate --format '{{.State.OOMKilled}}' 2>/dev/null)
  docker rm -f ops-oom-gate >/dev/null 2>&1

  OOM_FILHO=""; OOM_CONTA=""
  case "$OOM_SAIDA" in *filho=*) OOM_FILHO=$(printf '%s\n' "$OOM_SAIDA" | sed -n 's/^filho=//p') ;; esac
  case "$OOM_SAIDA" in *oom_kill=*) OOM_CONTA=$(printf '%s\n' "$OOM_SAIDA" | sed -n 's/^oom_kill=//p') ;; esac

  if [ "${OOM_CONTA:-0}" -ge 1 ] 2>/dev/null && [ "$OOM_FILHO" = "137" ]; then
    ok "OOM killer: o kernel contou oom_kill (=${OOM_CONTA}) e a saída foi 137 (128+9, SIGKILL) — o Docker reportou OOMKilled=${OOM_FLAG:-?}"
  elif [ "$OOM_FILHO" = "137" ]; then
    bad "OOM: a saída foi 137 mas memory.events não contou oom_kill (leu '${OOM_CONTA:-vazio}')"
  else
    bad "OOM: o processo não foi morto por SIGKILL (saída '${OOM_FILHO:-vazia}', oom_kill '${OOM_CONTA:-vazio}')"
  fi

  # ── DNS: um rótulo desconhecido custa segundos; dois rótulos inexistentes
  # custam milissegundos. É a diferença entre errar o nome de um serviço e
  # errar um domínio — e a primeira é a que parece "a rede está lenta".
  DNS_JSON=$(docker compose "${PROD[@]}" exec -T worker python3 -c '
import socket,time,json
def ms(n):
    t=time.monotonic()
    try:
        socket.gethostbyname(n); ok=True
    except Exception:
        ok=False
    return round((time.monotonic()-t)*1000,1), ok
lento,_ = ms("naoexisteninguem")
rapido,_ = ms("zq7x4k2m9p1v3n8w.com")
bom,okb = ms("db")
print(json.dumps({"rotuloUnico":lento,"doisRotulos":rapido,"db":bom,"dbOk":okb}))' 2>/dev/null | tail -1)
  M_DNS_LENTO=$(printf '%s' "$DNS_JSON" | python3 -c "import sys,json;v=json.load(sys.stdin).get('rotuloUnico');print('' if v is None else v)" 2>/dev/null)
  M_DNS_RAPIDO=$(printf '%s' "$DNS_JSON" | python3 -c "import sys,json;v=json.load(sys.stdin).get('doisRotulos');print('' if v is None else v)" 2>/dev/null)
  case "$DNS_JSON" in
    *'"dbOk": true'*) ok "DNS: o nome de um companheiro de rede resolve" ;;
    *) bad "DNS: o worker não resolve 'db' — a rede data quebrou" ;;
  esac
  # ── A checagem afirma a GRANDEZA ESTÁVEL, não a razão.
  #
  # A primeira versão exigia `lento > 100 × rapido`, e reprovou numa execução
  # com 7461,8 ms contra 145,8 ms — 51×, porque o resolvedor de cima estava
  # lento naquele instante. A razão oscila com uma latência que não é nossa; o
  # que NÃO oscila é a ordem de grandeza de cada lado: um rótulo desconhecido
  # espera o timeout (segundos), dois rótulos voltam com NXDOMAIN (sub-segundo).
  # É a armadilha 42 do CLAUDE.md — ao citar número medido, prefira o estável.
  if [ -n "$M_DNS_LENTO" ] && [ -n "$M_DNS_RAPIDO" ] &&
     python3 -c "
import sys
lento, rapido = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if lento > 1000 and rapido < 1000 else 1)" "$M_DNS_LENTO" "$M_DNS_RAPIDO"; then
    ok "DNS: rótulo único desconhecido leva SEGUNDOS (${M_DNS_LENTO}ms) e dois rótulos, milissegundos (${M_DNS_RAPIDO}ms)"
  else
    bad "a assimetria do DNS não apareceu (${M_DNS_LENTO:-?}ms x ${M_DNS_RAPIDO:-?}ms)"
  fi

  # ── Postgres: a biblioteca carregada, a extensão criada, e o cache que o
  # planejador acredita ter. `-T` no exec pela armadilha 31.
  PSQL_C='PGPASSWORD=$(cat /run/secrets/postgres_password) psql -U links -d links -tAc'
  SPL=$(docker compose "${PROD[@]}" exec -T db sh -c "$PSQL_C \"SHOW shared_preload_libraries;\"" 2>/dev/null | tr -d '\r ')
  if [ "$SPL" = "pg_stat_statements" ]; then
    ok "postgres: pg_stat_statements carregado em shared_preload_libraries"
  else
    bad "postgres: shared_preload_libraries='${SPL:-vazio}' (esperado pg_stat_statements)"
  fi
  docker compose "${PROD[@]}" exec -T db sh -c \
    "$PSQL_C \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\"" >/dev/null 2>&1
  EXT=$(docker compose "${PROD[@]}" exec -T db sh -c \
    "$PSQL_C \"SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements';\"" 2>/dev/null | tr -d '\r ')
  if [ "$EXT" = "1" ]; then
    ok "postgres: a extensão existe no banco (a biblioteca é a outra metade)"
  else
    bad "postgres: a extensão pg_stat_statements não está criada"
  fi

  ECS=$(docker compose "${PROD[@]}" exec -T db sh -c "$PSQL_C \"SHOW effective_cache_size;\"" 2>/dev/null | tr -d '\r ')
  MEM_DB=$(docker compose "${PROD[@]}" exec -T db cat /sys/fs/cgroup/memory.max 2>/dev/null | tr -d '\r ')
  if python3 -c "
import re, sys
v, lim = sys.argv[1].strip(), sys.argv[2].strip()
mult = {'kB': 1024, 'MB': 1048576, 'GB': 1073741824}
m = re.match(r'(\d+)(kB|MB|GB)', v)
sys.exit(0 if m and lim.isdigit() and int(m.group(1)) * mult[m.group(2)] <= int(lim) else 1)" \
     "$ECS" "$MEM_DB"; then
    ok "postgres: effective_cache_size ($ECS) cabe no cgroup ($((MEM_DB/1048576)) MiB)"
  else
    bad "postgres: effective_cache_size=$ECS é maior que o limite do container ($MEM_DB bytes)"
  fi
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
