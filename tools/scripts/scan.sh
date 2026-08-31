#!/usr/bin/env bash
# Escaneia as imagens da stack com o Trivy e gera SBOMs.
#
# Duas decisões de projeto neste script:
#
# 1. O Trivy analisa um TARBALL exportado por `docker save`, não o daemon. Assim
#    ele não precisa do socket do Docker — o que evita a concessão de SELinux
#    que o acesso ao socket exigiria, funciona em Docker rootless e funciona
#    igual num runner de CI. Custa um `docker save` por imagem.
#
# 2. Falha de FERRAMENTA e ACHADO DE VULNERABILIDADE são coisas diferentes.
#    Usamos `--exit-code 3` para os achados: 3 significa "encontrei CVEs",
#    qualquer outro código não-zero significa "o scanner quebrou". Sem essa
#    separação, um Trivy que não consegue nem abrir a imagem é reportado como
#    "vulnerabilidades encontradas" — e o portão de qualidade passa a mentir.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORTS="$ROOT/tools/reports"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
# Exceções documentadas e com prazo de validade. Ver tools/trivyignore.yaml.
IGNOREFILE="$ROOT/tools/trivyignore.yaml"
VULN_EXIT=3
mkdir -p "$REPORTS"

IMAGES=(
  "infra-knowlogy/api-go:dev"
  "infra-knowlogy/worker-py:dev"
  "infra-knowlogy/web:dev"
)

# Cache num volume nomeado: sem ele, cada execução rebaixa o banco de
# vulnerabilidades inteiro (centenas de MB).
docker volume create trivy-cache >/dev/null 2>&1

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

vulnerable=0
broken=0

for image in "${IMAGES[@]}"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "   ⊘ $image não existe — rode 'make build' antes." >&2
    broken=1
    continue
  fi

  safe="${image//[\/:]/_}"
  tar="$workdir/${safe}.tar"
  docker save "$image" -o "$tar"

  echo "── trivy: $image"
  docker run --rm \
    -v "$workdir":/scan:z \
    -v "$IGNOREFILE":/trivyignore.yaml:ro,z \
    -v trivy-cache:/root/.cache/trivy \
    aquasec/trivy:latest image \
      --quiet --scanners vuln \
      --ignorefile /trivyignore.yaml \
      --severity "$SEVERITY" \
      --ignore-unfixed \
      --exit-code "$VULN_EXIT" \
      --format table \
      --input "/scan/${safe}.tar"
  case $? in
    0) echo "   ✓ limpo" ;;
    "$VULN_EXIT") vulnerable=1 ;;
    *) echo "   ✗ o scanner falhou nesta imagem (não é o mesmo que ter CVE)" >&2; broken=1 ;;
  esac

  # SBOM em CycloneDX: a lista do que existe dentro da imagem. É o que permite
  # responder "eu uso a versão vulnerável?" no dia em que sai uma CVE nova, sem
  # precisar reconstruir e reescanear tudo.
  docker run --rm \
    -v "$workdir":/scan:z \
    -v trivy-cache:/root/.cache/trivy \
    -v "$REPORTS":/out:z \
    aquasec/trivy:latest image \
      --quiet --format cyclonedx --output "/out/${safe}.sbom.json" \
      --input "/scan/${safe}.tar" >/dev/null 2>&1
done

if [ "$broken" -eq 1 ]; then
  echo "   → o SCANNER falhou. Isto não é um veredito sobre as imagens." >&2
  exit 2
fi
if [ "$vulnerable" -eq 1 ]; then
  echo "   → vulnerabilidades $SEVERITY com correção disponível." >&2
  exit 1
fi
echo "   nenhuma vulnerabilidade $SEVERITY corrigível. SBOMs em tools/reports/."
