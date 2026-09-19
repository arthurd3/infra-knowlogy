# lib/jenkins.sh — falar com um Jenkins headless sem apanhar.
#
# Contrato com o chamador (não é executável, é um `source`):
#   JENKINS_URL  — ex.: http://localhost:8090
#   JK_USER      — usuário administrador
#   JK_PASS      — a senha (só para cunhar o token)
#   JK_TOKEN     — preenchido por jk_mint_token; depois disso, é o que se usa
#
# As pegadinhas abaixo custaram tempo real e estão aqui para não custarem de
# novo:
#
#   1. O Jenkins responde 503 durante a inicialização, com a página "Please
#      wait while Jenkins is getting ready to work". `curl -f` transforma esse
#      503 legítimo num erro de rede e some com a distinção entre "ainda
#      subindo" e "morreu". Por isso nenhuma função de espera usa -f.
#   2. O crumb de CSRF é ligado à SESSÃO. Buscar o crumb sem cookie jar e
#      postar depois dá 403 "No valid crumb was included in the request".
#   3. Autenticação por API token DISPENSA o crumb (Jenkins >= 2.96 weekly /
#      2.107 LTS). Por isso o caminho é: senha -> cunha token -> esquece CSRF.
#   4. `lastBuild` CORRE. Dois disparos no mesmo segundo e você lê o build
#      errado. O caminho certo é fila -> executable.number.
#   5. Os colchetes do parâmetro `tree` precisam ser percent-encoded. Sem isso
#      a resposta vem vazia ou truncada, e sem erro nenhum — já perdi tempo
#      com isso aqui.
#   6. O nó embutido se chama `(built-in)` desde o Jenkins 2.307, com os
#      parênteses na URL. E o `builtOn` de um build feito nele é STRING VAZIA,
#      não "built-in" e não null.
#   7. O `jenkins-cli` por WebSocket recusa com `X-CLI-Error: Unexpected
#      request origin` quando a URL usada não bate com a configurada em
#      `unclassified.location.url`. Use sempre a mesma origem.

# curl autenticado. Usa token se já houver, senão a senha.
jk_curl() {
  local auth="${JK_TOKEN:-$JK_PASS}"
  curl -s -m "${JK_TIMEOUT:-20}" -u "$JK_USER:$auth" "$@"
}

# Percent-encode dos colchetes do `tree`, que é a única parte que morde.
jk_tree() { printf '%s' "$1" | sed 's/\[/%5B/g; s/\]/%5D/g'; }

# GET que devolve JSON. $1 = caminho, $2 = expressão tree (opcional).
jk_json() {
  local path="$1" tree="${2:-}"
  if [ -n "$tree" ]; then
    jk_curl "$JENKINS_URL$path?tree=$(jk_tree "$tree")"
  else
    jk_curl "$JENKINS_URL$path"
  fi
}

# Lê um campo escalar de um JSON vindo da stdin. Ex.: jk_field numExecutors
jk_field() { python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1" 2>/dev/null; }

# Espera o controller ficar pronto. $1 = timeout em segundos (padrão 180).
# Ecoa os segundos que levou; devolve 1 se estourar.
jk_wait_ready() {
  local limite="${1:-180}" i hdr code
  for i in $(seq 1 "$limite"); do
    # Sem -f de propósito: o 503 do boot é informação, não erro de rede.
    hdr=$(curl -s -o /dev/null -D- -m 5 "$JENKINS_URL/login" 2>/dev/null)
    code=$(printf '%s' "$hdr" | head -1 | awk '{print $2}')
    # 200 = pronto. 403 = pronto, e anônimo sem leitura — também serve.
    case "$code" in
      200|403)
        # O header X-Jenkins só aparece depois de o core subir; o 200 da
        # página de "aguarde" não o traz.
        if printf '%s' "$hdr" | grep -qi '^x-jenkins:'; then printf '%s' "$i"; return 0; fi ;;
    esac
    sleep 1
  done
  return 1
}

# Cunha um API token a partir da senha. Ecoa o token.
jk_mint_token() {
  local jar crumb_field crumb resposta
  jar=$(mktemp)
  # O cookie jar é obrigatório: o crumb vale para a sessão que o emitiu.
  read -r crumb_field crumb <<<"$(curl -s -c "$jar" -m 15 -u "$JK_USER:$JK_PASS" \
    "$JENKINS_URL/crumbIssuer/api/json" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"],d["crumb"])' 2>/dev/null)"
  [ -n "${crumb:-}" ] || { rm -f "$jar"; return 1; }

  resposta=$(curl -s -b "$jar" -m 15 -u "$JK_USER:$JK_PASS" -H "$crumb_field: $crumb" \
    -X POST "$JENKINS_URL/user/$JK_USER/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken?newTokenName=cicd-verify")
  rm -f "$jar"
  printf '%s' "$resposta" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["tokenValue"])' 2>/dev/null
}

# Dispara um job e espera terminar. $1 = nome do job, $2 = timeout (padrão 600).
# Ecoa "<resultado> <numero>"; resultado é SUCCESS/FAILURE/ABORTED/TIMEOUT.
jk_build() {
  local job="$1" limite="${2:-600}" fila num i estado
  # 201 Created, corpo VAZIO: o que interessa está no header Location.
  fila=$(jk_curl -o /dev/null -D- -X POST "$JENKINS_URL/job/$job/build?delay=0sec" \
         | sed -n 's|^[Ll]ocation: *\(.*queue/item/[0-9]*\)/\?.*|\1|p' | tr -d '\r')
  [ -n "$fila" ] || { printf 'NO_QUEUE 0'; return 1; }

  # Fila -> número do build. NUNCA lastBuild: dois disparos no mesmo segundo
  # e você lê o build do vizinho.
  for i in $(seq 1 120); do
    num=$(jk_curl "$fila/api/json" \
      | python3 -c 'import sys,json;e=json.load(sys.stdin).get("executable");print(e["number"] if e else "")' 2>/dev/null)
    [ -n "$num" ] && break
    sleep 1
  done
  [ -n "${num:-}" ] || { printf 'STUCK_IN_QUEUE 0'; return 1; }

  for i in $(seq 1 "$limite"); do
    estado=$(jk_json "/job/$job/$num/api/json" "building,result" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(("BUILDING" if d["building"] else d["result"]) or "UNKNOWN")' 2>/dev/null)
    [ "$estado" != "BUILDING" ] && { printf '%s %s' "$estado" "$num"; return 0; }
    sleep 1
  done
  printf 'TIMEOUT %s' "$num"
  return 1
}

# Por que um item está parado na fila. Salva depuração: "Waiting for next
# available executor" significa agente offline (ou você esqueceu que o
# controller tem 0 executores).
jk_queue_why() {
  jk_curl "$JENKINS_URL/queue/api/json" \
    | python3 -c 'import sys,json
for i in json.load(sys.stdin).get("items",[]):
    print(i.get("why","?"))' 2>/dev/null
}

jk_console()  { jk_curl "$JENKINS_URL/job/$1/$2/consoleText"; }
jk_stages()   { jk_curl "$JENKINS_URL/job/$1/$2/wfapi/describe"; }
jk_built_on() { jk_json "/job/$1/$2/api/json" "builtOn" | jk_field builtOn; }
