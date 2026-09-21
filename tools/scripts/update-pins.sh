#!/usr/bin/env bash
# Atualiza os digests sha256 de toda referência `imagem:tag@sha256:...` do
# repositório.
#
# Pinar por digest torna o build reprodutível, mas congela também as correções
# de segurança. Este script é a outra metade do processo: ele move o pin de
# propósito, num commit revisável, em vez de o pin envelhecer calado.
#
# ─── Por que ele é de DUAS FASES ────────────────────────────────────────────
# A primeira versão resolvia e escrevia arquivo a arquivo. Numa execução em que
# o Docker Hub começou a responder 429 no meio, ela atualizou os 7 primeiros e
# desistiu dos 17 seguintes — deixando o `postgres:17-alpine` com UM digest no
# `stack/compose.yaml` e OUTRO no `iac/variables.tf` e nos manifests do k8s.
#
# Isso quebra em silêncio a afirmação central do repositório: que os módulos
# 1, 2 e 4 rodam a MESMA stack. O portão não pegaria — cada módulo constrói e
# passa sozinho, com imagens diferentes.
#
# Agora: resolve TODAS as imagens primeiro, e só escreve se todas resolverem.
# Falha parcial não escreve nada.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ─── Os arquivos que carregam digest ─────────────────────────────────────────
# Esquecer um NÃO dá erro: o `make pins` atualiza o resto e deixa aquele para
# trás, em silêncio. Por isso a lista é explícita e comentada.
arquivos() {
  {
    find "$ROOT/stack" "$ROOT/site" "$ROOT/cicd" -name Dockerfile -o -name 'compose*.yaml'
    # Módulo Kubernetes: kindest/node no kind-config, as imagens dos manifests,
    # e o metrics-server dos addons.
    find "$ROOT/k8s" -name '*.yaml' 2>/dev/null
    echo "$ROOT/Makefile"
    echo "$ROOT/tools/scripts/k8s-verify.sh"
    # Módulo IaC: os mesmos digests do compose.yaml aparecem de novo no
    # variables.tf (o provider Docker quer a referência como string), e a
    # imagem do próprio OpenTofu no lib/tofu.sh.
    find "$ROOT/iac" -name '*.tf' 2>/dev/null
    echo "$ROOT/tools/scripts/lib/tofu.sh"
    # As imagens de FERRAMENTA dos próprios portões. Ficaram de fora por muito
    # tempo — o hadolint chegou a rodar em `:latest`, o que deixava o portão
    # livre para mudar de comportamento sem commit nenhum. Uma ferramenta que
    # decide se o build passa é tão dependência quanto uma imagem base.
    echo "$ROOT/tools/scripts/verify.sh"
    echo "$ROOT/tools/scripts/cicd-verify.sh"
    echo "$ROOT/tools/scripts/ops-measure.py"
    echo "$ROOT/tools/scripts/k8s-helm-vs-kustomize.py"
  } | grep -v node_modules | sort -u
}

PADRAO='[a-z0-9][a-z0-9./_-]*(:[a-zA-Z0-9._-]+)?@sha256:[a-f0-9]{64}'

# ─── Fase 1: descobrir e resolver ────────────────────────────────────────────
declare -A NOVO=()        # imagem -> digest novo
declare -A ANTIGOS=()     # imagem -> digests encontrados hoje (pode ser >1)
nao_resolvidas=0
total=0

echo "── resolvendo"
while IFS= read -r ref; do
  image="${ref%@*}"
  old="${ref#*@}"
  ANTIGOS["$image"]="${ANTIGOS[$image]:-} $old"
  [ -n "${NOVO[$image]:-}" ] && continue     # já resolvida nesta execução
  total=$((total+1))
  new=$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null || true)
  if [ -z "$new" ]; then
    echo "   ⊘ não consegui resolver $image" >&2
    nao_resolvidas=$((nao_resolvidas+1))
    continue
  fi
  NOVO["$image"]="$new"
done < <(arquivos | xargs grep -ohE "$PADRAO" 2>/dev/null | sort -u)

if [ "$nao_resolvidas" -gt 0 ]; then
  echo
  echo "   ✗ $nao_resolvidas de $total imagem(ns) não puderam ser checadas." >&2
  echo "     NADA foi escrito — atualização parcial deixaria a mesma imagem com" >&2
  echo "     digests diferentes entre os módulos, e o portão não pegaria isso." >&2
  echo "     Causa comum: o Docker Hub responde 429 a pull anônimo. Tente de" >&2
  echo "     novo mais tarde, ou autentique-se com 'docker login'." >&2
  exit 2
fi

# ─── Fase 2: escrever, com o MESMO digest em todo lugar ──────────────────────
echo
echo "── aplicando"
mudou=0
for image in "${!NOVO[@]}"; do
  new="${NOVO[$image]}"
  aplicou=0
  for old in $(printf '%s\n' ${ANTIGOS[$image]} | sort -u); do
    [ "$old" = "$new" ] && continue
    while IFS= read -r file; do
      if grep -qF "${image}@${old}" "$file"; then
        sed -i "s|${image}@${old}|${image}@${new}|g" "$file"
        aplicou=1
      fi
    done < <(arquivos)
  done
  if [ "$aplicou" -eq 1 ]; then
    printf '   ↑ %-52s %s…\n' "$image" "${new:0:19}"
    mudou=1
  else
    printf '   = %-52s (inalterado)\n' "$image"
  fi
done

# ─── Fase 3: a conferência que a versão antiga não tinha ─────────────────────
# Depois de escrever, toda imagem tem que ter UM digest só no repositório
# inteiro. É a invariante que a atualização parcial quebrava.
echo
divergentes=$(arquivos | xargs grep -ohE "$PADRAO" 2>/dev/null \
  | sed 's/@/ /' | sort -u | awk '{print $1}' | uniq -d)
if [ -n "$divergentes" ]; then
  echo "   ✗ imagens com MAIS DE UM digest depois da atualização:" >&2
  printf '     %s\n' $divergentes >&2
  exit 1
fi
echo "   ✓ cada imagem tem um digest só no repositório inteiro"

[ "$mudou" -eq 1 ] \
  && echo "   pins atualizados. Rode 'make verify' antes de commitar." \
  || echo "   todos os pins conferidos e já atualizados."
exit 0
