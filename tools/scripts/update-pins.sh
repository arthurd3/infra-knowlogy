#!/usr/bin/env bash
# Atualiza os digests sha256 de todo `FROM imagem:tag@sha256:...` do repositório.
#
# Pinar por digest torna o build reprodutível, mas congela também as correções
# de segurança. Este script é a outra metade do processo: ele move o pin de
# propósito, num commit revisável, em vez de o pin envelhecer calado.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
changed=0
# "Não consegui checar" NÃO é "está atualizado". O Docker Hub responde 429 a
# pull anônimo com alguma frequência, e a primeira versão deste script
# terminava com "todos os pins já estão atualizados" depois de falhar em
# resolver dez imagens. É a mesma distinção que o scan.sh faz entre "o scanner
# quebrou" e "o scanner achou CVE": juntar as duas faz o portão mentir.
unresolved=0

while IFS= read -r file; do
  # Casa `FROM ref:tag@sha256:...` e também as imagens pinadas no Compose.
  while IFS= read -r ref; do
    image="${ref%@*}"
    old="${ref#*@}"
    new=$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null || true)

    if [ -z "$new" ]; then
      echo "   ⊘ não consegui resolver $image" >&2
      unresolved=$((unresolved+1))
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
done < <({ find "$ROOT/stack" "$ROOT/site" "$ROOT/cicd" -name Dockerfile -o -name 'compose*.yaml';
           # Módulo Kubernetes: kindest/node no kind-config, as imagens
           # pinadas nos manifests, e o kubeconform (Makefile e k8s-verify).
           find "$ROOT/k8s" -name '*.yaml' 2>/dev/null;
           echo "$ROOT/Makefile";
           echo "$ROOT/tools/scripts/k8s-verify.sh"; } | grep -v node_modules)

echo
if [ "$changed" -eq 1 ]; then
  echo "   pins atualizados. Rode 'make verify' antes de commitar."
fi
if [ "$unresolved" -gt 0 ]; then
  echo "   ⚠  $unresolved imagem(ns) NÃO puderam ser checadas — o pin delas pode"
  echo "      estar velho e este script não tem como saber. Causa comum: o"
  echo "      Docker Hub responde 429 a pull anônimo. Tente de novo mais tarde"
  echo "      ou autentique-se com 'docker login'."
  exit 2
fi
[ "$changed" -eq 0 ] && echo "   todos os pins conferidos e atualizados."
exit 0
