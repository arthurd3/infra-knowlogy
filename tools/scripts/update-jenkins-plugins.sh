#!/usr/bin/env bash
# Regera cicd/controller/plugins.txt com o fecho transitivo PINADO.
#
# O `update-pins.sh` move digest de imagem; este move versão de plugin. São a
# mesma ideia (ADR 0004): o pin congela junto com a correção de segurança, então
# ele precisa de um processo que o mova de propósito, num commit revisável, em
# vez de envelhecer calado.
#
# Os plugins de primeiro nível ficam no topo deste script, não num arquivo à
# parte: eles são a DECISÃO (o que este módulo precisa), e o plugins.txt é o
# RESULTADO (o que isso implica hoje). Misturar os dois foi o que fez a primeira
# versão pinar sete linhas e deixar sessenta soltas.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JENKINS_IMAGE="${JENKINS_IMAGE:-jenkins/jenkins:lts-jdk21}"
OUT="$ROOT/cicd/controller/plugins.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/seed.txt" <<'EOF'
configuration-as-code
job-dsl
workflow-aggregator
pipeline-stage-view
git
matrix-auth
credentials-binding
EOF

printf '\033[1m── Resolvendo o fecho transitivo dos plugins (precisa de rede)\033[0m\n'

docker run --rm -v "$TMP":/seed:z --entrypoint sh "$JENKINS_IMAGE" -c '
  jenkins-plugin-cli --plugin-file /seed/seed.txt >/dev/null 2>&1
  for f in /usr/share/jenkins/ref/plugins/*.jpi; do
    n=$(basename "$f" .jpi)
    v=$(unzip -p "$f" META-INF/MANIFEST.MF 2>/dev/null | tr -d "\r" | awk "/^Plugin-Version:/{print \$2}")
    [ -n "$v" ] && echo "$n:$v"
  done | sort > /seed/resolvidos.txt
'

n=$(wc -l < "$TMP/resolvidos.txt")
[ "$n" -gt 10 ] || { echo "   ✗ só $n plugins resolvidos — algo deu errado" >&2; exit 1; }

{
  sed -n '1,/^# ── de primeiro nível/p' "$OUT" 2>/dev/null || true
  # Se o cabeçalho ainda não existe (primeira execução), escreve um.
  if [ ! -s "$OUT" ]; then
    echo "# Plugins do controller, PINADOS por versão."
    echo "# Para regenerar: bash tools/scripts/update-jenkins-plugins.sh"
    echo "# ── de primeiro nível"
  fi
  sed 's/^/#   /' "$TMP/seed.txt"
  cat "$TMP/resolvidos.txt"
} > "$TMP/novo.txt"

if [ -f "$OUT" ] && diff -q "$OUT" "$TMP/novo.txt" >/dev/null 2>&1; then
  printf '   = %s plugins, todos já na versão atual\n' "$n"
else
  mv "$TMP/novo.txt" "$OUT"
  printf '   ↑ %s plugins pinados -> %s\n' "$n" "${OUT#"$ROOT"/}"
  printf '   rode "make cicd-verify" antes de commitar.\n'
fi
