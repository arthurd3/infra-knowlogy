#!/usr/bin/env bash
# Atualiza os digests sha256 de todo `FROM imagem:tag@sha256:...` do repositório.
#
# Pinar por digest torna o build reprodutível, mas congela também as correções
# de segurança. Este script é a outra metade do processo: ele move o pin de
# propósito, num commit revisável, em vez de o pin envelhecer calado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
changed=0

while IFS= read -r file; do
  # Casa `FROM ref:tag@sha256:...` e também as imagens pinadas no Compose.
  while IFS= read -r ref; do
    image="${ref%@*}"
    old="${ref#*@}"
    new=$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null || true)

    if [ -z "$new" ]; then
      echo "   ⊘ não consegui resolver $image" >&2
      continue
    fi
    if [ "$new" = "$old" ]; then
      printf '   = %-58s (inalterado)\n' "$image"
      continue
    fi

    sed -i "s|${image}@${old}|${image}@${new}|g" "$file"
    printf '   ↑ %-58s\n     %s -> %s\n' "$image" "${old:0:19}…" "${new:0:19}…"
    changed=1
  done < <(grep -ohE '[a-z0-9./_-]+(:[a-zA-Z0-9._-]+)?@sha256:[a-f0-9]{64}' "$file" | sort -u)
done < <(find "$ROOT/stack" "$ROOT/site" -name Dockerfile -o -name 'compose*.yaml' | grep -v node_modules)

if [ "$changed" -eq 1 ]; then
  echo
  echo "   pins atualizados. Rode 'make verify' antes de commitar."
else
  echo "   todos os pins já estão atualizados."
fi
