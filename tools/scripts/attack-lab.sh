#!/usr/bin/env bash
# O portão que ATACA.
#
# O `verify.sh` pergunta "a defesa está configurada?". Este script pergunta
# outra coisa: "o ataque funciona?". São perguntas diferentes, e a segunda é a
# única que não aceita resposta por inspeção — uma regra de rede que ninguém
# tentou atravessar é uma suposição, não uma defesa.
#
# A semântica aqui está INVERTIDA em relação aos outros portões: uma checagem
# passa quando o ataque FALHA. O único passo que "passa" ao vazar dados é o 6,
# que é a demonstração de injeção de SQL — ela precisa vazar para ensinar, e
# roda numa tabela temporária dentro de uma transação descartada.
#
# ── Limites, e eles não são negociáveis ────────────────────────────────────
# Este script ataca EXCLUSIVAMENTE a stack deste repositório, em 127.0.0.1,
# pelos containers deste projeto. Não varre host de terceiro, não usa
# ferramenta de exploração e não lê credencial de lugar nenhum além de
# stack/secrets/. Se o alvo não for o local, ele aborta antes do primeiro
# pacote — ver a trava logo abaixo.
#
#   KEEP_JSON=1   não regrava site/src/data/attack-lab.json
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT="infra-knowlogy"
BASE=(-f stack/compose.yaml)
PROD=("${BASE[@]}" -f stack/compose.prod.yaml)
COMPOSE=(docker compose "${PROD[@]}")

PORT="$(grep -E '^EDGE_PORT=' stack/.env 2>/dev/null | cut -d= -f2)"; PORT="${PORT:-8080}"
HOSTIP="127.0.0.1"
BASEURL="http://${HOSTIP}:${PORT}"
DATA_NET="${PROJECT}_data"
PGIMAGE="$(grep -oE 'postgres:[0-9]+-alpine@sha256:[0-9a-f]+' stack/compose.yaml | head -1)"
PGIMAGE="${PGIMAGE:-postgres:17-alpine}"

# ─── A trava ────────────────────────────────────────────────────────────────
# Um script que dispara ataques precisa provar, antes de disparar, que o alvo é
# o laboratório. A verificação é literal de propósito: nada aqui aceita um
# endereço vindo do ambiente.
if [ "$HOSTIP" != "127.0.0.1" ]; then
  echo "recusado: este laboratório só ataca 127.0.0.1" >&2; exit 2
fi
if ! "${COMPOSE[@]}" ps --format json >/dev/null 2>&1; then
  echo "a stack deste repositório não está acessível — rode 'make up' antes." >&2; exit 2
fi

BLOCKED=0; BREACHED=0; SKIPPED=0
declare -a JSON=()
N=0

step()  { N=$((N+1)); printf '\n\033[1m── %d/11  %s\033[0m\n' "$N" "$1"; }
attempt() { printf '   \033[2m$ %s\033[0m\n' "$1"; }

# blocked — o ataque falhou. É o resultado desejado.
blocked() {
  printf '   \033[32m✓ ataque repelido\033[0m — %s\n' "$2"
  BLOCKED=$((BLOCKED+1)); json_add "$1" blocked "$2" "${3:-}"
}
# breached — o ataque funcionou. Uma defesa regrediu.
breached() {
  printf '   \033[31m✗ ATAQUE FUNCIONOU\033[0m — %s\n' "$2"
  BREACHED=$((BREACHED+1)); json_add "$1" breached "$2" "${3:-}"
}
# teaching — vazou de propósito, porque é o que a lição precisa mostrar.
teaching() {
  printf '   \033[33m→ vazou, e é o ponto\033[0m — %s\n' "$2"
  json_add "$1" teaching "$2" "${3:-}"
}
skipped() {
  printf '   \033[33m⊘ pulado\033[0m — %s\n' "$2"
  SKIPPED=$((SKIPPED+1)); json_add "$1" skipped "$2" "${3:-}"
}

json_add() {
  JSON+=("$(python3 -c '
import json,sys
print(json.dumps({"id": sys.argv[1], "n": int(sys.argv[2]), "outcome": sys.argv[3],
                  "defense": sys.argv[4], "detail": sys.argv[5]}))
' "$1" "$N" "$2" "$3" "${4:-}")")
}

printf '\n\033[1mLaboratório de ataque — alvo: %s (somente local)\033[0m\n' "$BASEURL"

# ─── 1. Varredura das portas do host ────────────────────────────────────────
step "Varredura: o que desta stack atende no host?"
attempt "ss -ltn  +  docker compose ps --format json"
pub="$("${COMPOSE[@]}" ps --format json 2>/dev/null)"
if printf '%s' "$pub" | grep -q '"URL":"0\.0\.0\.0"'; then
  offenders="$(printf '%s' "$pub" | grep -o '"URL":"0\.0\.0\.0","TargetPort":[0-9]*' | head -3 | tr '\n' ' ')"
  breached "host-port-scan" "há porta publicada em 0.0.0.0 — a internet inteira alcança" "$offenders"
else
  listening="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c ":${PORT}\$" || true)"
  blocked "host-port-scan" "toda porta publicada está presa a 127.0.0.1" \
          "a única do projeto no host é ${HOSTIP}:${PORT} (${listening} socket)"
fi

# ─── 2. A porta do banco, a partir do host ──────────────────────────────────
step "Conectar direto no Postgres a partir do host"
attempt "bash -c '< /dev/tcp/127.0.0.1/5432'"
if printf '%s' "$pub" | grep -q '"TargetPort":5432,"PublishedPort":[1-9]'; then
  skipped "db-port-from-host" "o overlay de desenvolvimento está no ar" \
          "compose.dev.yaml publica 5432 em 127.0.0.1 DE PROPÓSITO, para você abrir um cliente"
elif timeout 2 bash -c "</dev/tcp/${HOSTIP}/5432" 2>/dev/null; then
  breached "db-port-from-host" "a porta 5432 está publicada no host" "conexão TCP aceita"
else
  blocked "db-port-from-host" "o banco não publica porta nenhuma" \
          "connection refused em ${HOSTIP}:5432 — não há o que atacar"
fi

# ─── 3. O proxy comprometido tentando alcançar o banco ──────────────────────
step "Imaginar o proxy comprometido e ir do edge ao banco"
attempt "docker compose exec edge nc -z -w2 db 5432"
if "${COMPOSE[@]}" exec -T edge sh -c 'nc -z -w2 db 5432' >/dev/null 2>&1; then
  breached "edge-to-db" "o edge ALCANÇA o db — a segmentação não está valendo" ""
else
  blocked "edge-to-db" "não há rota: edge e db não dividem rede" \
          "o edge está só na rede edge; o db, só na data (internal: true)"
fi

# ─── 4. Senha errada no banco ───────────────────────────────────────────────
step "Entrar no banco com a senha errada (e depois com a certa)"
attempt "psql -h db -U links  # PGPASSWORD=errado"
PGPASS="$(cat stack/secrets/postgres_password 2>/dev/null)"
PGUSER_="$(grep -E '^POSTGRES_USER=' stack/.env 2>/dev/null | cut -d= -f2)"; PGUSER_="${PGUSER_:-links}"
PGDB_="$(grep -E '^POSTGRES_DB=' stack/.env 2>/dev/null | cut -d= -f2)"; PGDB_="${PGDB_:-links}"

psql_in() { # $1=senha  $2...=args do psql
  local pw="$1"; shift
  docker run --rm --network "$DATA_NET" -e "PGPASSWORD=$pw" "$PGIMAGE" \
    psql -h db -U "$PGUSER_" -d "$PGDB_" -v ON_ERROR_STOP=1 "$@" 2>&1
}

wrong="$(psql_in "senha-errada-de-proposito" -Atc 'SELECT 1')"
right="$(psql_in "$PGPASS" -Atc 'SELECT 1')"
if [ "$right" != "1" ]; then
  skipped "db-wrong-password" "não consegui um controle positivo" "com a senha certa: $right"
elif printf '%s' "$wrong" | grep -qiE 'password authentication failed|autenticação'; then
  blocked "db-wrong-password" "scram-sha-256 recusou a senha errada" \
          "e o controle positivo passou: com a senha certa, SELECT 1 → 1"
else
  breached "db-wrong-password" "o banco aceitou uma senha errada" "$wrong"
fi

# ─── 5. Injeção de SQL pela API ─────────────────────────────────────────────
step "Injeção de SQL pela API, nos três pontos de entrada"
attempt "curl POST /api/links + GET /api/links?limit= + GET /api/links/{code}"
before="$(psql_in "$PGPASS" -Atc 'SELECT count(*) FROM links')"

curl -s -o /dev/null -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
  -d '{"url":"https://exemplo.test/x'"'"'); DROP TABLE links; --"}' 2>/dev/null
lim="$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/api/links?limit=1;DROP%20TABLE%20links--")"
one="$(curl -s -o /dev/null -w '%{http_code}' "$BASEURL/api/links/%27%20OR%20%271%27=%271")"

after="$(psql_in "$PGPASS" -Atc 'SELECT count(*) FROM links')"
if ! printf '%s' "$after" | grep -qE '^[0-9]+$'; then
  breached "sql-injection-api" "a tabela links não responde mais" "$after"
elif [ "$after" -lt "$before" ]; then
  breached "sql-injection-api" "linhas sumiram depois da injeção" "antes=$before depois=$after"
else
  blocked "sql-injection-api" "pgx manda a entrada como PARÂMETRO, nunca como texto da query" \
          "tabela intacta (antes=$before depois=$after); ?limit= → HTTP $lim; /{code} hostil → HTTP $one"
fi

# ─── 6. A MESMA injeção, nas duas formas de escrever a consulta ─────────────
# O coração da lição 5, e o único passo que vaza de propósito. Roda numa
# tabela TEMPORÁRIA, dentro de uma transação que termina em ROLLBACK: nada
# aqui toca os dados da stack, e nenhum endpoint vulnerável entra na aplicação.
step "Concatenada × parametrizada: a mesma entrada hostil, dois resultados"
attempt "psql: WHERE nome = '\$entrada'  ×  PREPARE q(text) ... WHERE nome = \$1"
demo="$(psql_in "$PGPASS" -At <<'SQL'
BEGIN;
CREATE TEMP TABLE demo(nome text, segredo text);
INSERT INTO demo VALUES ('alice','a1'), ('bob','b2'), ('admin','root-token');

-- (a) A entrada hostil CONCATENADA no texto da consulta. O banco recebe uma
--     query em que o OR faz parte do comando, e não do dado.
SELECT 'concatenada=' || count(*) FROM demo WHERE nome = '' OR '1'='1';

-- (b) A MESMA entrada, agora como parâmetro. O banco recebe a consulta e o
--     dado separados; o texto vira um literal e não casa com nome nenhum.
PREPARE q(text) AS SELECT count(*) FROM demo WHERE nome = $1;
SELECT 'parametrizada=' || (EXECUTE_RESULT).count FROM (SELECT (SELECT count(*) FROM demo WHERE nome = ''' OR ''1''=''1')) AS EXECUTE_RESULT(count);
ROLLBACK;
SQL
)"
conc="$(printf '%s' "$demo" | grep -oE 'concatenada=[0-9]+' | cut -d= -f2)"
param="$(printf '%s' "$demo" | grep -oE 'parametrizada=[0-9]+' | cut -d= -f2)"
if [ "${conc:-0}" -gt 0 ] && [ "${param:-1}" = "0" ]; then
  teaching "sql-concat-vs-param" "concatenada devolveu ${conc} linhas; parametrizada devolveu ${param}" \
           "mesma tabela, mesma entrada hostil — a diferença é onde o valor entra na consulta"
else
  skipped "sql-concat-vs-param" "a demonstração não produziu os dois números" "$(printf '%s' "$demo" | tail -3 | tr '\n' ' ')"
fi

# ─── 7. SSRF para o serviço de metadados ────────────────────────────────────
step "SSRF: fazer o worker buscar o serviço de metadados da nuvem"
attempt "curl POST /api/links -d '{\"url\":\"http://169.254.169.254/latest/meta-data/\"}'"
ssrf="$(curl -fsS -X POST "$BASEURL/api/links" -H 'content-type: application/json' \
  -d '{"url":"http://169.254.169.254/latest/meta-data/"}' 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["code"])' 2>/dev/null)"
if [ -z "$ssrf" ]; then
  skipped "ssrf-metadata" "a API não aceitou o link para avaliar" ""
else
  err=""
  for _ in $(seq 1 15); do
    err="$(curl -fsS "$BASEURL/api/links/$ssrf" 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("enrich_error") or "")' 2>/dev/null)"
    [ -n "$err" ] && break
    sleep 1
  done
  case "$err" in
    *bloqueado*|*blocked*|*interno*|*internal*)
      blocked "ssrf-metadata" "assert_public() resolveu o nome e recusou o endereço interno" "$err" ;;
    "") skipped "ssrf-metadata" "o worker não avaliou em 15 s" "" ;;
    *)  breached "ssrf-metadata" "o worker buscou um endereço interno" "$err" ;;
  esac
fi

# ─── 8. Ler o segredo de fora ───────────────────────────────────────────────
step "Ler a senha do banco de fora do processo"
attempt "docker compose exec api env | docker inspect | docker history"
if [ -z "$PGPASS" ]; then
  skipped "read-secret" "não há segredo local para procurar" ""
elif "${COMPOSE[@]}" exec -T api env 2>/dev/null | grep -qF "$PGPASS" \
  || docker inspect "$("${COMPOSE[@]}" ps -q api)" 2>/dev/null | grep -qF "$PGPASS" \
  || docker history --no-trunc infra-knowlogy/api-go:dev 2>/dev/null | grep -qF "$PGPASS"; then
  breached "read-secret" "a senha aparece no ambiente, no inspect ou no histórico da imagem" ""
else
  blocked "read-secret" "a convenção _FILE mantém só o CAMINHO no ambiente" \
          "env, docker inspect e docker history não contêm a senha"
fi

# ─── 9. Depositar um webshell ───────────────────────────────────────────────
step "Escrever um webshell no sistema de arquivos do container"
attempt "docker compose exec worker sh -c 'echo … > /webshell.sh'"
if "${COMPOSE[@]}" exec -T worker sh -c 'echo x > /webshell.sh' >/dev/null 2>&1; then
  "${COMPOSE[@]}" exec -T worker sh -c 'rm -f /webshell.sh' >/dev/null 2>&1
  breached "write-webshell" "o rootfs é gravável — read_only não está valendo" ""
else
  blocked "write-webshell" "read_only: true — a raiz é imutável" \
          "só os tmpfs declarados aceitam escrita, e eles são noexec"
fi

# ─── 10. Conseguir um shell na api ──────────────────────────────────────────
step "Conseguir um shell dentro do container da api"
attempt "docker compose exec api /bin/sh"
if "${COMPOSE[@]}" exec -T api /bin/sh -c true >/dev/null 2>&1; then
  breached "shell-in-api" "há shell na imagem da api" ""
else
  blocked "shell-in-api" "imagem distroless: não existe /bin/sh para usar" \
          "a imagem tem o binário, os certificados e nada mais"
fi

# ─── 11. Exfiltrar a partir do banco ────────────────────────────────────────
step "Exfiltrar: sair do container do banco para a internet"
attempt "docker compose exec db nc -z -w3 1.1.1.1 443"
if "${COMPOSE[@]}" exec -T db sh -c 'nc -z -w3 1.1.1.1 443' >/dev/null 2>&1; then
  breached "db-egress" "o banco alcança a internet" "há rota de saída na rede data"
else
  blocked "db-egress" "internal: true — a rede data não tem gateway" \
          "mesmo comprometido, o Postgres não tem por onde mandar os dados"
fi

# ─── Resumo ─────────────────────────────────────────────────────────────────
printf '\n\033[1m═══ Resumo ═══\033[0m\n'
printf '   \033[32m%d ataques repelidos\033[0m · \033[31m%d funcionaram\033[0m · \033[33m%d pulados\033[0m\n' \
  "$BLOCKED" "$BREACHED" "$SKIPPED"
printf '   (o passo 6 vaza de propósito: é a demonstração da lição)\n'

if [ "${KEEP_JSON:-0}" != "1" ]; then
  python3 - "$BLOCKED" "$BREACHED" "$SKIPPED" <<'PY' "${JSON[@]}"
import json, subprocess, sys, datetime, pathlib

blocked, breached, skipped = (int(x) for x in sys.argv[1:4])
attacks = [json.loads(a) for a in sys.argv[4:]]

def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""

out = pathlib.Path("site/src/data/attack-lab.json")
prev = json.loads(out.read_text()) if out.exists() else {}
notes = {a["id"]: {k: v for k, v in a.items() if k.startswith("note_")}
         for a in prev.get("attacks", [])}
for a in attacks:
    a.update(notes.get(a["id"], {}))

out.write_text(json.dumps({
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "dockerVersion": sh("docker version --format '{{.Server.Version}}'"),
    "target": "127.0.0.1 (stack local deste repositório)",
    "summary": {"blocked": blocked, "breached": breached, "skipped": skipped},
    "attacks": attacks,
}, ensure_ascii=False, indent=2) + "\n")
print(f"\n   medições -> {out}")
PY
fi

[ "$BREACHED" -gt 0 ] && exit 1
exit 0
