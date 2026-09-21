#!/usr/bin/env bash
# O portão do módulo CI/CD. Roda tudo e falha alto.
#
# Mesma ideia dos outros dois (ADR 0007): cada afirmação que as lições fazem
# sobre este módulo vira uma checagem. Se o isolamento regredir, se um plugin
# sair do pin, se o pipeline parar de reprovar o que deve reprovar — este
# script reprova, e a lição correspondente deixa de estar mentindo.
#
# Portão INDEPENDENTE: quem estuda só Docker não instala Jenkins.
#
#   SKIP_BUILD=1      pula o pipeline completo (o mais caro)
#   SKIP_NEGATIVE=1   pula a prova de que o pipeline reprova
#   SKIP_REPRO=1      pula a comparação com o `docker build` local
#   KEEP_JENKINS=1    não derruba no fim (para iterar)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
CICD="$ROOT/cicd"
COMPOSE=(docker compose -f "$CICD/compose.yaml")

PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()
step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); RESULTS+=("PASS  $1"); }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); }
skip() { printf '   \033[33m⊘\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); RESULTS+=("SKIP  $1"); }
now_ms() { date +%s%3N; }

# Medições. `null` quando não medido — o widget precisa saber a diferença
# entre "zero" e "não rodou".
M_BOOT_S=null; M_AGENT_S=null; M_PIPE_S=null; M_LINT_S=null; M_BUILD_S=null
M_WARM_S=null; M_PLUGINS=null; M_BIN_MATCH=null; M_DIGEST_MATCH=null
M_SCAN_S=null; M_SIGN_S=null

# ─── 1. Estático, sem subir nada ─────────────────────────────────────────────
step "1/8  Lint estático e pins"

if "${COMPOSE[@]}" config -q 2>/dev/null; then ok "compose config"; else bad "compose config"; fi

for f in $(find "$CICD" -name Dockerfile -not -path '*/fixtures/bad/*' | sort); do
  rel="${f#"$ROOT"/}"
  if docker run --rm -i hadolint/hadolint:latest@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d hadolint --no-color - < "$f" >/tmp/cicd-hl.txt 2>&1; then
    ok "hadolint $rel"
  else
    bad "hadolint $rel"; sed 's/^/       /' /tmp/cicd-hl.txt | head -6
  fi
done

# Pin por digest (ADR 0004) vale aqui como em todo lugar. A fixture negativa é
# a exceção: ela existe para ser ruim.
#
# `[[:space:]]` e não `\s`: o ERE do grep NÃO conhece as classes do Perl, e
# `\s` casa a letra "s". A primeira versão desta checagem reprovou arquivos
# perfeitamente pinados por causa disso.
naopinados=""
while IFS= read -r f; do
  case "$f" in */fixtures/bad/*) continue ;; esac
  while IFS= read -r linha; do
    case "$linha" in *@sha256:*) ;; *) naopinados="$naopinados${f#"$ROOT"/}: $linha"$'\n' ;; esac
  done < <(grep -E '^FROM[[:space:]]+' "$f" 2>/dev/null)
done < <(find "$CICD" -name Dockerfile)

if [ -z "$naopinados" ]; then
  ok "todo FROM de cicd/ está pinado por digest"
else
  bad "FROM sem digest em cicd/"; printf '%s' "$naopinados" | sed 's/^/       /' 
fi

semversao=$(grep -vE '^\s*#|^\s*$' "$CICD/controller/plugins.txt" | grep -cvE '^[a-z0-9-]+:[0-9]' || true)
M_PLUGINS=$(grep -vcE '^\s*#|^\s*$' "$CICD/controller/plugins.txt")
if [ "${semversao:-1}" -eq 0 ]; then
  ok "os $M_PLUGINS plugins estão pinados por versão"
else
  bad "$semversao plugin(s) sem versão em plugins.txt"
fi

# ─── 2. O controller nasce pronto ────────────────────────────────────────────
step "2/8  O controller sobe do casc, sem clique"

t0=$(now_ms)
if bash "$ROOT/tools/scripts/cicd-up.sh" >/tmp/cicd-up.txt 2>&1; then
  M_BOOT_S=$(( ($(now_ms) - t0) / 1000 ))
  ok "cicd-up.sh completo em ${M_BOOT_S}s"
else
  bad "cicd-up.sh falhou"; tail -15 /tmp/cicd-up.txt | sed 's/^/       /'
  printf '\n   \033[31mabortando: sem stack não há o que verificar\033[0m\n\n'; exit 1
fi

# shellcheck disable=SC1091
source "$ROOT/tools/scripts/lib/jenkins.sh"
PORT=$(grep -E '^JENKINS_PORT=' "$CICD/.env" | cut -d= -f2)
export JENKINS_URL="http://localhost:${PORT:-8090}" JK_USER=admin
JK_PASS="$(cat "$CICD/secrets/jenkins_admin_password")"; export JK_PASS
JK_TOKEN=""; export JK_TOKEN
JK_TOKEN=$(jk_mint_token)
[ -n "$JK_TOKEN" ] && ok "API token cunhado (crumb + cookie de sessão)" || bad "não consegui cunhar o token"

"${COMPOSE[@]}" exec -T controller test -f /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null \
  && bad "initialAdminPassword existe — o assistente de instalação rodou" \
  || ok "nenhum assistente: initialAdminPassword não existe"

# A armadilha que mais custa: chave errada no JCasC é IGNORADA em silêncio.
# Log para variável antes do grep, pelo mesmo motivo do console mais abaixo:
# com pipefail, `comando | grep -q` inverte o resultado quando o grep acerta e
# fecha o pipe. Aqui a inversão seria PIOR que no outro caso — ela reportaria
# "nenhuma chave ignorada" justamente quando houvesse uma.
cascalog=$("${COMPOSE[@]}" logs controller 2>&1)
if case "$cascalog" in *"Unknown key"*|*"unknown key"*|*"Unable to configure"*) true ;; *) false ;; esac; then
  bad "o JCasC ignorou alguma chave em silêncio"
  printf '%s' "$cascalog" | grep -iE "unknown key|Unable to configure" | head -4 | sed 's/^/       /'
else
  ok "o JCasC aplicou tudo (nenhum 'Unknown key' no log)"
fi

inst=$(jk_curl "$JENKINS_URL/pluginManager/api/json?depth=1&tree=$(jk_tree 'plugins[shortName,version,active,failed]')")
if printf '%s' "$inst" | python3 "$ROOT/tools/scripts/lib/cmp-plugins.py" "$CICD/controller/plugins.txt" >/tmp/cicd-plug.txt 2>&1; then
  ok "os $M_PLUGINS plugins ativos batem exatamente com o pinado"
else
  bad "plugins divergem do pin"; sed 's/^/       /' /tmp/cicd-plug.txt
fi

# ─── 3. Isolamento controller/agente ─────────────────────────────────────────
step "3/8  O controller não constrói nada"

n=$(jk_json '/computer/(built-in)/api/json' 'numExecutors' | jk_field numExecutors)
[ "$n" = "0" ] && ok "built-in com 0 executores" || bad "built-in com $n executores (esperado 0)"

p=$(jk_json '/api/json' 'slaveAgentPort' | jk_field slaveAgentPort)
[ "$p" = "-1" ] && ok "porta TCP de agente desligada (-1)" || bad "slaveAgentPort=$p (esperado -1)"

off=$(jk_json '/computer/builder/api/json' 'offline' | jk_field offline)
[ "$off" = "False" ] && ok "agente builder online (por WebSocket, sem porta TCP)" || bad "agente offline"

"${COMPOSE[@]}" exec -T agent test -S /var/run/docker.sock 2>/dev/null \
  && bad "o agente ENXERGA /var/run/docker.sock" \
  || ok "o agente não enxerga o socket do Docker"

"${COMPOSE[@]}" exec -T agent sh -c 'command -v docker' >/dev/null 2>&1 \
  && bad "o agente tem o docker CLI" \
  || ok "o agente não tem o docker CLI"

priv=0
for s in controller buildkitd agent registry scm; do
  cid=$("${COMPOSE[@]}" ps -q "$s" 2>/dev/null)
  [ -n "$cid" ] || continue
  [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid")" = "true" ] && { bad "$s está privilegiado"; priv=1; }
done
[ "$priv" -eq 0 ] && ok "nenhum container privilegiado"

# A prova de que o SELinux continua confinando o construtor, e não foi
# desligado com label=disable (ADR 0011).
lbl=$(docker inspect -f '{{.ProcessLabel}}' "$("${COMPOSE[@]}" ps -q buildkitd)" | cut -d: -f3)
[ "$lbl" = "container_engine_t" ] && ok "buildkitd confinado como container_engine_t" \
  || bad "buildkitd com rótulo '$lbl' (esperado container_engine_t)"

portas=$("${COMPOSE[@]}" ps --format '{{.Ports}}' 2>/dev/null)
if case "$portas" in *0.0.0.0*) true ;; *) false ;; esac; then
  bad "algo publicado em 0.0.0.0"
else
  ok "tudo publicado só em 127.0.0.1"
fi

# ─── 4. Os jobs nascem do seed ───────────────────────────────────────────────
step "4/8  Os jobs vêm de código, não de clique"

declarados=$(grep -oE "pipelineJob\('([^']+)'\)" "$CICD/controller/jobs/seed.groovy" | sed "s/pipelineJob('\(.*\)')/\1/" | sort | tr '\n' ' ')

# O seed é ASSÍNCRONO. O Jenkins responde /login — e o jk_wait_ready dá por
# pronto — antes de o JCasC terminar de aplicar e de o Job DSL rodar. A
# primeira versão desta checagem reprovava por corrida, não por defeito:
# prontidão de HTTP não é configuração aplicada.
for _ in $(seq 1 60); do
  existem=$(jk_json '/api/json' 'jobs[name]' | python3 -c 'import sys,json;print(" ".join(sorted(j["name"] for j in json.load(sys.stdin).get("jobs",[]))))' 2>/dev/null)
  [ "$(echo "$declarados" | xargs)" = "$(echo "$existem" | xargs)" ] && break
  sleep 1
done
if [ "$(echo "$declarados" | xargs)" = "$(echo "$existem" | xargs)" ]; then
  ok "os jobs são exatamente os do seed: $existem"
else
  bad "jobs divergem do seed"; printf '       seed:    %s\n       jenkins: %s\n' "$declarados" "$existem"
fi

val=$(jk_curl -X POST -F "jenkinsfile=<$CICD/Jenkinsfile" "$JENKINS_URL/pipeline-model-converter/validate")
case "$val" in
  *"successfully validated"*) ok "o Jenkinsfile passa no linter declarativo do Jenkins" ;;
  *) bad "Jenkinsfile recusado pelo linter"; printf '       %s\n' "$val" | head -4 ;;
esac

# ─── 5. O pipeline roda ──────────────────────────────────────────────────────
step "5/8  O pipeline, de ponta a ponta"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  skip "pipeline completo (SKIP_BUILD=1)"
else
  t0=$(now_ms)
  read -r resultado numero <<<"$(jk_build stack-pipeline 1800)"
  M_PIPE_S=$(( ($(now_ms) - t0) / 1000 ))
  if [ "$resultado" = "SUCCESS" ]; then
    ok "stack-pipeline #$numero terminou SUCCESS em ${M_PIPE_S}s"
  else
    bad "stack-pipeline terminou $resultado"
    jk_console stack-pipeline "$numero" 2>/dev/null | tail -12 | sed 's/^/       /'
  fi

  # O `builtOn` de um build de Pipeline é string vazia MESMO quando tudo rodou
  # no agente — ele reporta o executor flyweight, que fica no controller. Quem
  # prova que o build saiu de lá é o console.
  #
  # Casamento com `case`, SEM pipe — e isso não é estilo.
  #
  # Com `set -o pipefail`, `printf "$grande" | grep -q PADRÃO` INVERTE o
  # resultado quando o padrão aparece cedo: o `grep -q` sai no primeiro acerto
  # e fecha o pipe, o `printf` ainda tem dezenas de kB para escrever e morre de
  # SIGPIPE, e o pipefail propaga esse não-zero. ACHAR vira "não achei".
  #
  # O detalhe que esconde o defeito: com uma entrada PEQUENA o printf termina
  # de escrever antes de o grep sair, e o mesmo código funciona. Aqui "Running
  # on builder" está na linha 20 de 571 — e a checagem negativa, cujo padrão
  # aparece no fim do log, passava sem problema. O mesmo código, dois
  # resultados, dependendo de onde o padrão está.
  console=$(jk_console stack-pipeline "$numero" 2>/dev/null)
  case "$console" in
    *"Running on builder"*) ok "o build rodou no agente, não no controller" ;;
    *) bad "não encontrei 'Running on builder' no console" ;;
  esac

  est=$(jk_stages stack-pipeline "$numero" 2>/dev/null)
  M_LINT_S=$(printf '%s' "$est" | python3 -c 'import sys,json
try: print(next(s["durationMillis"]/1000 for s in json.load(sys.stdin)["stages"] if s["name"]=="lint"))
except Exception: print("null")' 2>/dev/null)
  M_BUILD_S=$(printf '%s' "$est" | python3 -c 'import sys,json
try: print(next(s["durationMillis"]/1000 for s in json.load(sys.stdin)["stages"] if s["name"]=="build"))
except Exception: print("null")' 2>/dev/null)
  for etapa in scan sign; do
    v=$(printf '%s' "$est" | python3 -c "
import sys, json
try: print(next(s['durationMillis']/1000 for s in json.load(sys.stdin)['stages'] if s['name']=='$etapa'))
except Exception: print('null')" 2>/dev/null)
    [ "$etapa" = "scan" ] && M_SCAN_S="$v" || M_SIGN_S="$v"
  done
  nomes=$(printf '%s' "$est" | python3 -c 'import sys,json;print(",".join(s["name"] for s in json.load(sys.stdin).get("stages",[])))' 2>/dev/null)
  case "$nomes" in
    *lint*build*scan*sign*verify*archive*)
      ok "estágios na ordem esperada: lint, build, scan, sign, verify, archive" ;;
    *) bad "estágios inesperados: $nomes" ;;
  esac

  arts=$(jk_json "/job/stack-pipeline/$numero/api/json" 'artifacts[fileName]' \
         | python3 -c 'import sys,json;print(" ".join(sorted(a["fileName"] for a in json.load(sys.stdin).get("artifacts",[]))))' 2>/dev/null)
  [ "$arts" = "api-go.tar web.tar worker-py.tar" ] \
    && ok "três artefatos arquivados: $arts" \
    || bad "artefatos inesperados: $arts"

  # Segunda execução: o cache do buildkitd já está quente. É o número que
  # sustenta a comparação com o GitHub Actions, onde o runner é descartado.
  t0=$(now_ms)
  read -r r2 n2 <<<"$(jk_build stack-pipeline 1800)"
  M_WARM_S=$(( ($(now_ms) - t0) / 1000 ))
  [ "$r2" = "SUCCESS" ] \
    && ok "segunda execução (cache quente) em ${M_WARM_S}s, contra ${M_PIPE_S}s frio" \
    || bad "a segunda execução terminou $r2"
fi

# ─── 6. O pipeline reprova quando deve ───────────────────────────────────────
step "6/8  A prova negativa"

if [ "${SKIP_NEGATIVE:-0}" = "1" ]; then
  skip "prova negativa (SKIP_NEGATIVE=1)"
else
  read -r rneg nneg <<<"$(jk_build stack-negative-lint 900)"
  if [ "$rneg" = "FAILURE" ]; then
    ok "stack-negative-lint REPROVOU, como tem que reprovar"
    negcon=$(jk_console stack-negative-lint "$nneg" 2>/dev/null)
    case "$negcon" in
      *DL3006*|*DL3009*|*DL3015*) ok "e reprovou pelo motivo certo (violação de hadolint no console)" ;;
      *) bad "reprovou, mas o console não mostra a violação de hadolint" ;;
    esac
  else
    bad "stack-negative-lint terminou $rneg — o lint NÃO está recusando nada"
  fi
fi

# ─── 7. Credenciais e assinatura ─────────────────────────────────────────────
step "7/8  O que o mascaramento faz, e o que não faz"

if [ "${SKIP_BUILD:-0}" = "1" ]; then
  skip "sonda de credencial (SKIP_BUILD=1)"
else
  segredo=$(cat "$CICD/secrets/registry_token" 2>/dev/null)
  b64=$(printf '%s' "$segredo" | base64)
  invertido=$(printf '%s' "$segredo" | rev)

  read -r rcred ncred <<<"$(jk_build credential-probe 600)"
  if [ "$rcred" = "SUCCESS" ]; then
    log=$(jk_console credential-probe "$ncred" 2>/dev/null)
    case "$log" in
      *"$segredo"*) bad "o valor literal da credencial aparece no console" ;;
      *) ok "o valor literal da credencial sai mascarado" ;;
    esac

    # Este aqui contraria o exemplo que mais se repete na internet. Se um dia
    # o Jenkins parar de registrar o base64, esta checagem avisa — e a lição
    # que afirma o contrário precisa ser reescrita.
    case "$log" in
      *"$b64"*) bad "o base64 da credencial vazou — a lição afirma que ele é mascarado" ;;
      *) ok "o base64 também sai mascarado (contra o que se repete por aí)" ;;
    esac

    # E este prova que mascaramento NÃO é fronteira: basta sair do conjunto de
    # representações que o plugin conhece.
    case "$log" in
      *"$invertido"*) ok "o segredo INVERTIDO passa inteiro — mascaramento não é fronteira" ;;
      *) bad "o invertido não apareceu; a lição afirma que ele passa" ;;
    esac
  else
    bad "credential-probe terminou $rcred"
  fi
fi

# ─── 8. O artefato é o mesmo do build local ──────────────────────────────────
step "8/8  Reprodutibilidade"

if [ "${SKIP_REPRO:-0}" = "1" ] || [ "${SKIP_BUILD:-0}" = "1" ]; then
  skip "comparação com o build local (SKIP_REPRO/SKIP_BUILD)"
else
  tmp=$(mktemp -d)
  jk_curl -o "$tmp/api-go.tar" "$JENKINS_URL/job/stack-pipeline/$numero/artifact/out/api-go.tar" 2>/dev/null
  if docker load -q -i "$tmp/api-go.tar" >/dev/null 2>&1 \
     && docker build -q --target dist -t cicd-verify/api-go:local "$ROOT/stack/services/api-go" >/dev/null 2>&1; then
    pega() { c=$(docker create "$1" 2>/dev/null) && docker cp "$c:/api-go" "$2" >/dev/null 2>&1 && docker rm "$c" >/dev/null; }
    pega infra-knowlogy/api-go:ci "$tmp/jenkins"
    pega cicd-verify/api-go:local "$tmp/local"
    if cmp -s "$tmp/jenkins" "$tmp/local"; then
      M_BIN_MATCH=true
      ok "o binário Go do Jenkins é byte a byte igual ao do docker build local"
    else
      M_BIN_MATCH=false
      bad "o binário do Jenkins difere do local"
    fi
    # O digest da imagem INTEIRA pode divergir (timestamps, ordem no tar) sem
    # que nada esteja errado. Vira medição, não checagem — a lição explica.
    a=$(docker inspect -f '{{.Id}}' infra-knowlogy/api-go:ci 2>/dev/null)
    b=$(docker inspect -f '{{.Id}}' cicd-verify/api-go:local 2>/dev/null)
    [ "$a" = "$b" ] && M_DIGEST_MATCH=true || M_DIGEST_MATCH=false
    printf '   \033[2m   digest da imagem inteira igual: %s (medição, não checagem)\033[0m\n' "$M_DIGEST_MATCH"
    docker rmi -f cicd-verify/api-go:local >/dev/null 2>&1
  else
    bad "não consegui comparar (docker load ou docker build falhou)"
  fi
  rm -rf "$tmp"
fi

# ─── Medições ────────────────────────────────────────────────────────────────
python3 - "$M_BOOT_S" "$M_PIPE_S" "$M_WARM_S" "$M_LINT_S" "$M_BUILD_S" "$M_PLUGINS" \
         "$M_BIN_MATCH" "$M_DIGEST_MATCH" "$M_SCAN_S" "$M_SIGN_S" <<'PY'
import json, subprocess, sys, pathlib, datetime

def num(v):
    if v in ("null", "", None): return None
    try: return float(v) if "." in str(v) else int(v)
    except ValueError: return None

def boolean(v):
    return {"true": True, "false": False}.get(str(v), None)

boot, pipe, warm, lint, build, plugins, binmatch, digestmatch, scan, sign = sys.argv[1:11]
jenkins = subprocess.run(
    ["docker", "compose", "-f", "cicd/compose.yaml", "exec", "-T", "controller",
     "sh", "-c", "curl -sI http://localhost:8080/login | awk '/^[Xx]-[Jj]enkins:/{print $2}' | tr -d '\\r'"],
    capture_output=True, text=True).stdout.strip() or None

doc = {
    "generatedAt": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "jenkinsVersion": jenkins,
    "pluginsPinned": num(plugins),
    "measurements": {
        "controllerBootSeconds": num(boot),
        "pipelineColdSeconds": num(pipe),
        "pipelineWarmSeconds": num(warm),
        "lintStageSeconds": num(lint),
        "buildStageSeconds": num(build),
        "scanStageSeconds": num(scan),
        "signStageSeconds": num(sign),
        "goBinaryIdentical": boolean(binmatch),
        "imageDigestIdentical": boolean(digestmatch),
    },
}
p = pathlib.Path("site/src/data/cicd-measured.json")
p.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
print(f"   \033[32m✓\033[0m medições gravadas em {p}")
PY
PASS=$((PASS+1)); RESULTS+=("PASS  medições gravadas")

# ─── Teardown ────────────────────────────────────────────────────────────────
if [ "${KEEP_JENKINS:-0}" = "1" ]; then
  printf '\n   \033[33mKEEP_JENKINS=1 — o Jenkins continua no ar em %s\033[0m\n' "$JENKINS_URL"
else
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1
fi

printf '\n\033[1m═══ Resumo ═══\033[0m\n'
printf '   \033[32m%s passaram\033[0m · \033[31m%s falharam\033[0m · \033[33m%s puladas\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '\n   Falhas:\n'
  printf '%s\n' "${RESULTS[@]}" | grep '^FAIL' | sed 's/^/     /'
  exit 1
fi
printf '\n'
