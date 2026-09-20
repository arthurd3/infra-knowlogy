#!/usr/bin/env bash
# O portão do módulo 4 (IaC). Mesmo contrato do verify.sh: cada afirmação que
# as lições da trilha `iac` fazem vira uma checagem que falha alto.
#
# O que este portão prova, em uma frase: **o OpenTofu sobe a MESMA aplicação
# que o Compose sobe**, é idempotente, detecta o mundo mudando por baixo, e o
# estado dele é um arquivo que guarda o que você puser nele.
#
#   KEEP_STACK=1     não destrói no fim (para inspecionar à mão)
#   SKIP_NEGATIVE=1  pula a prova negativa do lock adulterado
#   SKIP_BUILD=1     assume as imagens já construídas
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/tofu.sh
source "$ROOT/tools/scripts/lib/tofu.sh"

PASS=0; FAIL=0; SKIP=0
step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '   \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '   \033[33m⊘\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
dim()  { printf '     \033[2m%s\033[0m\n' "$1"; }

EDGE_PORT=8082
BASEURL="http://127.0.0.1:$EDGE_PORT"
SENHA_FILE="$ROOT/stack/secrets/postgres_password"

# A chave da demonstração de cifragem. Ela é PÚBLICA de propósito: o que o
# portão prova é o mecanismo, não o sigilo desta frase em particular.
read -r -d '' ENC_CONFIG <<'ENC'
key_provider "pbkdf2" "portao" {
  passphrase = "frase-do-portao-longa-o-bastante-para-o-pbkdf2"
}
method "aes_gcm" "portao" {
  keys = key_provider.pbkdf2.portao
}
method "unencrypted" "migrar" {}
state {
  method = method.aes_gcm.portao
  fallback {
    method = method.unencrypted.migrar
  }
}
plan {
  method = method.aes_gcm.portao
  fallback {
    method = method.unencrypted.migrar
  }
}
ENC

secs() { date +%s.%N; }
delta() { python3 -c "print(round($2 - $1, 3))"; }

# ─── 1. Estático: o código antes de tocar em qualquer coisa ──────────────────
step "1/9  Lint e validação estática"

bash tools/scripts/init-secrets.sh >/dev/null 2>&1
if [ -r "$SENHA_FILE" ]; then ok "segredo do Postgres presente (o mesmo do módulo 1)"
else bad "stack/secrets/postgres_password ausente — rode make init"; fi

if tofu fmt -check -no-color >/tmp/iac-fmt.txt 2>&1; then
  ok "tofu fmt -check: o HCL está formatado"
else
  bad "tofu fmt -check reprovou"; sed 's/^/       /' /tmp/iac-fmt.txt | head -5
fi

T0=$(secs)
tofu init -no-color >/tmp/iac-init.txt 2>&1 || true
T_INIT=$(delta "$T0" "$(secs)")
if tofu validate -no-color >/tmp/iac-val.txt 2>&1; then
  ok "tofu validate: a configuração é válida"
else
  bad "tofu validate reprovou"; tail -6 /tmp/iac-val.txt | sed 's/^/       /'
fi

# ─── 2. O pin: versão E hash, como o ADR 0004 exige das imagens ──────────────
step "2/9  O provider está pinado por versão e por hash"

LOCK="$ROOT/iac/.terraform.lock.hcl"
if [ -f "$LOCK" ]; then
  # `[[:space:]]` e não `\s`: o ERE do grep -E não conhece `\s` (armadilha 27).
  if grep -qE '^[[:space:]]+version[[:space:]]+=[[:space:]]+"4\.6\.0"' "$LOCK"; then
    ok "versão do provider pinada no lock (4.6.0)"
  else
    bad "o lock não pina a versão esperada"
  fi
  h1=$(grep -c '"h1:' "$LOCK"); zh=$(grep -c '"zh:' "$LOCK")
  if [ "$h1" -gt 0 ] && [ "$zh" -gt 0 ]; then
    ok "lock traz os dois tipos de hash ($h1 × h1:, $zh × zh:)"
    dim "h1: é o hash do diretório extraído; zh: é o do zip assinado pelo registry"
  else
    bad "o lock não traz h1: e zh: (h1=$h1 zh=$zh)"
  fi
else
  bad ".terraform.lock.hcl ausente — o provider não está pinado"
fi

# A prova NEGATIVA: um lock adulterado tem que REPROVAR o init. Sem ela, o
# item acima prova só que o arquivo existe.
if [ "${SKIP_NEGATIVE:-0}" = "1" ]; then
  skip "prova negativa do lock (SKIP_NEGATIVE=1)"
else
  NEG="$ROOT/iac/.negative"
  rm -rf "$NEG"; mkdir -p "$NEG"
  cp "$ROOT/iac/versions.tf" "$LOCK" "$NEG/" 2>/dev/null
  # Adultera as DUAS famílias de hash, e a razão é o achado desta casa:
  # o lock guarda `zh:` (hash do zip assinado pelo registry) e `h1:` (hash do
  # diretório extraído), e o OpenTofu se dá por satisfeito se QUALQUER UMA
  # bater. Adulterando só as `h1:` — que foi a primeira versão desta checagem —
  # o `init` passava liso, e o portão anunciava uma proteção que não testou.
  python3 - "$NEG/.terraform.lock.hcl" <<'TAMPER'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'"h1:[A-Za-z0-9+/=]+"', '"h1:' + 'A' * 43 + '="', s)
s = re.sub(r'"zh:[0-9a-f]+"', '"zh:' + 'a' * 64 + '"', s)
open(p, 'w').write(s)
TAMPER
  if TOFU_SUBDIR=iac/.negative tofu init -no-color >/tmp/iac-neg.txt 2>&1; then
    bad "o init ACEITOU um lock com hashes adulterados — o pin não protege nada"
  else
    case "$(cat /tmp/iac-neg.txt)" in
      *"dependency lock file"*|*"checksum"*)
        ok "init REPROVA lock com os hashes adulterados"
        dim "adulterar só as h1: NÃO basta: as zh: ainda batem, e uma família já satisfaz" ;;
      *) bad "o init falhou, mas não por causa do hash"; tail -4 /tmp/iac-neg.txt | sed 's/^/       /' ;;
    esac
  fi
  rm -rf "$NEG"
fi

# ─── 3. plan em terreno limpo ────────────────────────────────────────────────
step "3/9  plan -detailed-exitcode num mundo sem a stack"

if [ -f "$ROOT/iac/terraform.tfstate" ] && [ "${KEEP_STACK:-0}" != "1" ]; then
  tofu destroy -no-color -auto-approve >/dev/null 2>&1 || true
fi

T0=$(secs); tofu plan -no-color -detailed-exitcode -out=tfplan.bin >/tmp/iac-plan.txt 2>&1; RC=$?
T_PLAN=$(delta "$T0" "$(secs)")
case "$RC" in
  2) ok "plan sai com 2 = há mudanças a aplicar (0 seria 'nada a fazer')" ;;
  0) bad "plan saiu 0 num mundo sem stack — ou ela já está de pé" ;;
  *) bad "plan falhou (exit $RC)"; tail -8 /tmp/iac-plan.txt | sed 's/^/       /' ;;
esac

# ─── 4. apply ────────────────────────────────────────────────────────────────
step "4/9  apply: subir a stack inteira"

T0=$(secs); tofu apply -no-color -auto-approve tfplan.bin >/tmp/iac-apply.txt 2>&1; RC=$?
T_APPLY=$(delta "$T0" "$(secs)")
if [ "$RC" -eq 0 ]; then
  ok "apply completou em ${T_APPLY}s"
else
  bad "apply falhou"; tail -12 /tmp/iac-apply.txt | sed 's/^/       /'
fi

ESPERADOS="iac-api iac-cache iac-db iac-edge iac-web iac-worker"
SAUDAVEIS=0
for c in $ESPERADOS; do
  st=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo ausente)
  [ "$st" = "healthy" ] && SAUDAVEIS=$((SAUDAVEIS+1))
done
if [ "$SAUDAVEIS" -eq 6 ]; then
  ok "os 6 containers estão healthy"
else
  bad "só $SAUDAVEIS de 6 containers healthy"
  docker ps -a --filter label=infra-knowlogy.module=iac --format '       {{.Names}} {{.Status}}'
fi

# Quantos objetos o estado passa a gerenciar. Sai do próprio estado, não de
# uma contagem à mão — número escrito à mão envelhece calado.
RECURSOS=$(python3 -c "
import json
d = json.load(open('$ROOT/iac/terraform.tfstate'))
print(sum(len(r.get('instances', [])) for r in d.get('resources', [])))" 2>/dev/null || echo 0)

# ─── 5. A mesma aplicação ────────────────────────────────────────────────────
# Este é o passo que justifica o módulo inteiro existir. O miolo vem de
# lib/smoke.sh, o MESMO arquivo que o verify.sh e o k8s-verify.sh usam.
step "5/9  Smoke test: é a mesma aplicação do módulo 1"

smoke_logs() { for s in "$@"; do docker logs --tail 20 "iac-$s" 2>&1 | sed 's/^/       /'; done; }
# shellcheck source=lib/smoke.sh
source "$ROOT/tools/scripts/lib/smoke.sh"
run_smoke

# ─── 6. Idempotência e drift ─────────────────────────────────────────────────
step "6/9  Idempotência e detecção de drift"

T0=$(secs); tofu plan -no-color -detailed-exitcode >/tmp/iac-plan2.txt 2>&1; RC=$?
T_PLAN_WARM=$(delta "$T0" "$(secs)")
if [ "$RC" -eq 0 ]; then
  ok "plan logo após o apply sai 0 — idempotente"
  dim "foi esta checagem que pegou CAP_CHOWN e memory_swap; ver iac/containers.tf"
else
  bad "plan pós-apply saiu $RC — a configuração não converge"
  grep -E '^  # |^Plan:' /tmp/iac-plan2.txt | head -8 | sed 's/^/       /'
fi

docker rm -f iac-worker >/dev/null 2>&1
tofu plan -no-color -refresh-only -detailed-exitcode >/tmp/iac-drift.txt 2>&1; RC=$?
DRIFT_TXT=$(cat /tmp/iac-drift.txt)
if [ "$RC" -eq 2 ]; then
  # `case` e não `| grep -q`: com pipefail, o grep -q fecha o pipe cedo e o
  # escritor morre de SIGPIPE, invertendo o resultado (armadilha 29).
  case "$DRIFT_TXT" in
    *"docker_container.worker has been deleted"*)
      ok "refresh-only detecta o worker apagado por fora e o NOMEIA" ;;
    *) bad "detectou drift mas não identificou o recurso" ;;
  esac
else
  bad "refresh-only saiu $RC depois de eu apagar um container (esperado 2)"
fi

tofu apply -no-color -auto-approve >/dev/null 2>&1
tofu plan -no-color -detailed-exitcode >/dev/null 2>&1
if [ $? -eq 0 ]; then
  ok "apply reconcilia o drift e o plan volta a 0"
else
  bad "o apply não reconciliou o drift"
fi

# ─── 7. O grafo ──────────────────────────────────────────────────────────────
step "7/9  O grafo: a ordem que ninguém escreveu"

tofu graph >/tmp/iac-graph.dot 2>/dev/null
GRAPH=$(cat /tmp/iac-graph.dot)
case "$GRAPH" in
  *'"[root] docker_container.api (expand)" -> "[root] docker_container.db (expand)"'*)
    ok "aresta IMPLÍCITA api -> db (nasceu de POSTGRES_HOST referenciar o recurso)" ;;
  *) bad "o grafo não tem a aresta api -> db" ;;
esac
case "$GRAPH" in
  *'"[root] docker_container.edge (expand)" -> "[root] docker_container.api (expand)"'*)
    ok "aresta EXPLÍCITA edge -> api (depends_on, porque o Caddyfile o tofu não lê)" ;;
  *) bad "o grafo não tem a aresta edge -> api" ;;
esac

# ─── 8. Segredo e estado ─────────────────────────────────────────────────────
step "8/9  O que o estado guarda"

SENHA=$(cat "$SENHA_FILE")
if grep -q "$SENHA" "$ROOT/iac/terraform.tfstate" 2>/dev/null; then
  bad "a senha do Postgres VAZOU para o estado do módulo"
else
  ok "a senha NÃO está no estado: a convenção <VAR>_FILE passa o caminho, não o valor"
fi
if grep -rq "$SENHA" "$ROOT"/iac/*.tf 2>/dev/null; then
  bad "a senha está escrita num .tf"
else
  ok "nenhum .tf contém a senha"
fi

# A demonstração deliberada: o mesmo segredo, agora DENTRO da configuração.
DEMO="$ROOT/iac/demo-secret"
rm -f "$DEMO/terraform.tfstate" "$DEMO/terraform.tfstate.backup"
( TOFU_SUBDIR=iac/demo-secret; tofu init -no-color >/dev/null 2>&1
  TOFU_SUBDIR=iac/demo-secret tofu apply -no-color -auto-approve >/dev/null 2>&1 )
N=$(grep -c "$SENHA" "$DEMO/terraform.tfstate" 2>/dev/null || echo 0)
if [ "${N:-0}" -gt 0 ]; then
  ok "com o segredo NA configuração, ele aparece $N× em texto puro no estado"
  dim "é o mesmo arquivo que vai para o bucket, para o backup e para o CI"
else
  bad "a demonstração de vazamento não vazou — ela perdeu o sentido"
fi

( export TF_ENCRYPTION="$ENC_CONFIG"
  TOFU_SUBDIR=iac/demo-secret tofu apply -no-color -auto-approve >/dev/null 2>&1 )
if grep -q "$SENHA" "$DEMO/terraform.tfstate" 2>/dev/null; then
  bad "a cifragem de estado não escondeu o segredo"
else
  CHAVES=$(python3 -c "import json;print(','.join(json.load(open('$DEMO/terraform.tfstate')).keys()))" 2>/dev/null)
  case "$CHAVES" in
    *encrypted_data*) ok "com TF_ENCRYPTION o estado vira envelope ($CHAVES) e o segredo some" ;;
    *) bad "o segredo sumiu, mas o arquivo não parece cifrado: $CHAVES" ;;
  esac
fi

if TOFU_SUBDIR=iac/demo-secret tofu plan -no-color >/tmp/iac-nokey.txt 2>&1; then
  bad "o tofu leu o estado cifrado SEM a chave"
else
  case "$(cat /tmp/iac-nokey.txt)" in
    *"encrypted"*) ok "sem a chave, o tofu recusa ler o estado cifrado" ;;
    *) bad "falhou sem a chave, mas por outro motivo"; tail -3 /tmp/iac-nokey.txt | sed 's/^/       /' ;;
  esac
fi
rm -f "$DEMO/terraform.tfstate" "$DEMO/terraform.tfstate.backup"
rm -rf "$DEMO/.terraform"

# ─── 9. destroy e o que sobra ────────────────────────────────────────────────
step "9/9  destroy, e provar que não sobrou nada"

VIZINHO=0
if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:8080/edge-health" 2>/dev/null; then VIZINHO=1; fi

if [ "${KEEP_STACK:-0}" = "1" ]; then
  skip "destroy (KEEP_STACK=1 — a stack fica de pé em $BASEURL)"
  T_DESTROY=0
else
  T0=$(secs); tofu destroy -no-color -auto-approve >/tmp/iac-destroy.txt 2>&1; RC=$?
  T_DESTROY=$(delta "$T0" "$(secs)")
  if [ "$RC" -eq 0 ]; then ok "destroy completou em ${T_DESTROY}s"
  else bad "destroy falhou"; tail -8 /tmp/iac-destroy.txt | sed 's/^/       /'; fi

  SOBRA=$(docker ps -aq --filter label=infra-knowlogy.module=iac | wc -l)
  SOBRA_NET=$(docker network ls -q --filter label=infra-knowlogy.module=iac | wc -l)
  SOBRA_VOL=$(docker volume ls -q --filter label=infra-knowlogy.module=iac | wc -l)
  if [ "$SOBRA" -eq 0 ] && [ "$SOBRA_NET" -eq 0 ] && [ "$SOBRA_VOL" -eq 0 ]; then
    ok "zero containers, redes e volumes com o rótulo do módulo"
    dim "as IMAGENS ficam de propósito (keep_locally): o Compose usa os mesmos digests"
  else
    bad "sobrou: $SOBRA containers, $SOBRA_NET redes, $SOBRA_VOL volumes"
  fi
fi

if [ "$VIZINHO" -eq 1 ]; then
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:8080/edge-health" 2>/dev/null; then
    ok "a stack do Compose na 8080 atravessou tudo isto intacta"
  else
    bad "a stack do Compose na 8080 caiu durante o portão do módulo 4"
  fi
else
  skip "stack do Compose não estava no ar (suba com make up para provar a convivência)"
fi

# ─── Medições ────────────────────────────────────────────────────────────────
MEASURED="$ROOT/site/src/data/iac-measured.json"
python3 - "$MEASURED" "$T_INIT" "$T_PLAN" "$T_PLAN_WARM" "$T_APPLY" "$T_DESTROY" "$RECURSOS" <<'PY'
import json, subprocess, sys
out, init, plan, plan_warm, apply, destroy, recursos = sys.argv[1:8]
gen = subprocess.run(["date","-u","+%Y-%m-%dT%H:%M:%SZ"], capture_output=True, text=True).stdout.strip()
json.dump({
  "generatedAt": gen,
  "tofuVersion": "1.12.3",
  "providerVersion": "kreuzwerker/docker 4.6.0",
  "measurements": {
    "initSeconds": float(init),
    # Os dois `plan` medem coisas DIFERENTES, e é por isso que o segundo é o
    # mais lento: o primeiro roda contra um estado vazio (não há o que
    # refrescar), o segundo consulta o daemon sobre cada recurso existente.
    # Chamar um de "frio" e o outro de "quente" inverteria a leitura.
    "planEmptyStateSeconds": float(plan),
    "planWithRefreshSeconds": float(plan_warm),
    "applySeconds": float(apply),
    "destroySeconds": float(destroy),
    "managedResources": int(recursos),
  },
}, open(out, "w"), indent=2, ensure_ascii=False)
open(out, "a").write("\n")
PY
ok "medições gravadas em site/src/data/iac-measured.json"

rm -f "$ROOT/iac/tfplan.bin"

printf '\n\033[1m── Resultado\033[0m\n'
printf '   \033[32m%d passaram\033[0m · \033[31m%d falharam\033[0m · \033[33m%d pulados\033[0m\n\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
