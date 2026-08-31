#!/usr/bin/env bash
# Mede o tamanho REAL de cada alvo de build e grava site/src/data/measured.json.
#
# Este script existe por um motivo específico: a lição sobre imagens base cita
# números. Números copiados de blog envelhecem e frequentemente estão errados
# para a SUA aplicação. Estes vêm do `docker image inspect` desta máquina, deste
# código, hoje — e são regerados a cada `make verify`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/site/src/data/measured.json"
PREFIX="iknow-measure"

# service|dir|target|base|nota
TARGETS=(
  "api-go|stack/services/api-go|minimal|scratch|Só o binário, os certificados CA e /etc/passwd, copiados à mão.|Just the binary, CA certificates and /etc/passwd, copied by hand."
  "api-go|stack/services/api-go|dist|distroless/static|Certificados, tzdata e usuário nonroot prontos. Sem shell.|CA certs, tzdata and a nonroot user, ready. No shell."
  "api-go|stack/services/api-go|debug|alpine|Tem shell e apk: dá para investigar, e dá para ser investigado.|Has a shell and apk: you can debug it, and so can an intruder."
  "worker-py|stack/services/worker-py|dist|python slim|Runtime + venv. O uv e o cache de wheels ficaram para trás.|Runtime + venv. uv and the wheel cache were left behind."
  "worker-py|stack/services/worker-py|fat|uv bookworm-slim|Antipadrão: uma stage só, o toolchain inteiro vai junto.|Anti-pattern: a single stage, so the whole toolchain ships too."
  "web|site|dist|caddy alpine|HTML estático servido pelo Caddy. Zero Node na imagem final.|Static HTML served by Caddy. Zero Node in the final image."
)

echo "medindo imagens (isto builda tudo; pode demorar na primeira vez)…"

rows=""
for spec in "${TARGETS[@]}"; do
  IFS='|' read -r service dir target base note_pt note_en <<< "$spec"
  tag="$PREFIX/$service:$target"

  docker build --quiet --target "$target" -t "$tag" "$ROOT/$dir" >/dev/null

  bytes=$(docker image inspect "$tag" --format '{{.Size}}')
  layers=$(docker image inspect "$tag" --format '{{len .RootFS.Layers}}')

  printf '  %-12s %-10s %8.1f MB  (%s camadas)\n' "$service" "$target" \
    "$(awk "BEGIN{print $bytes/1048576}")" "$layers"

  rows+="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$service" "$target" "$base" "$bytes" "$layers" "$note_pt" "$note_en")"$'\n'
done

# Linguagem por serviço, para o widget agrupar.
lang_of() {
  case "$1" in
    api-go)    echo "Go" ;;
    worker-py) echo "Python" ;;
    web)       echo "Node" ;;
    *)         echo "?" ;;
  esac
}

mkdir -p "$(dirname "$OUT")"
{
  echo '{'
  printf '  "generatedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "dockerVersion": "%s",\n' "$(docker version --format '{{.Server.Version}}')"
  printf '  "platform": "%s",\n' "$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"
  echo '  "images": ['
  first=1
  while IFS=$'\t' read -r service target base bytes layers note_pt note_en; do
    [ -z "$service" ] && continue
    [ $first -eq 0 ] && echo ','
    first=0
    printf '    {"service": "%s", "language": "%s", "target": "%s", "base": "%s", "bytes": %s, "layers": %s, "note_pt": "%s", "note_en": "%s"}' \
      "$service" "$(lang_of "$service")" "$target" "$base" "$bytes" "$layers" "$note_pt" "$note_en"
  done <<< "$rows"
  echo ''
  echo '  ]'
  echo '}'
} > "$OUT"

python3 -c "import json,sys; d=json.load(open('$OUT')); print(f'gravado {len(d[\"images\"])} medições em site/src/data/measured.json')"
