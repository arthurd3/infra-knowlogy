#!/usr/bin/env bash
# Como o `tofu` roda nesta casa — resolvido em UM lugar, usado pelo iac-up.sh,
# pelo iac-verify.sh e pelo Makefile.
#
# Duas vias, nesta ordem de preferência:
#
#   1. binário no host. Zero concessão: o `tofu` fala com o socket do Docker
#      exatamente como o `docker` da linha de comando já fala, pelo grupo
#      `docker` do usuário. Nenhum container, nenhum rótulo SELinux relaxado.
#
#   2. container oficial. É o que funciona numa máquina sem instalar nada, e
#      custa TRÊS alinhamentos que só apareceram medindo (ver ADR 0016):
#
#      a) SELinux. O padrão `container_t` e o `container_engine_t` — o tipo que
#         resolveu o socket do buildkitd no módulo 3 — são NEGADOS no
#         /var/run/docker.sock. Medido nesta máquina:
#
#           padrão              container_t:s0:c948,c1019    connect() negado
#           container_engine_t  container_engine_t:s0:c431..  connect() negado
#           label=disable       spc_t:s0                      connect() OK
#           label=type:spc_t    spc_t:s0:c55,c466             connect() OK
#
#         Os dois últimos dão o MESMO tipo. A diferença está nas categorias
#         MCS: o `label=disable` que todo tutorial cola sai SEM elas, o
#         `label=type:spc_t` sai COM. Mesma capacidade de falar com o daemon,
#         e o container continua sem alcançar arquivo de outro container.
#         Por isso aqui é `spc_t` explícito, e não `disable`.
#
#      b) DAC. O socket é `srw-rw---- root:docker`. Rodando com `--user` (que
#         é o que evita o `.terraform/` nascer do root no seu diretório), o
#         processo precisa do grupo: daí o `--group-add` com o gid lido do
#         próprio socket, que não é 969 em toda máquina.
#
#      c) Propriedade dos arquivos. Sem `--user`, o `terraform.tfstate` e o
#         `.terraform.lock.hcl` saem do root e você não consegue nem apagá-los
#         sem sudo. É a armadilha 10 do CLAUDE.md noutra roupa.
#
# Uma consequência que não é óbvia: na via 2 existem DOIS sistemas de arquivos
# na história. O contexto de build é lido pelo processo do `tofu` (caminho do
# CONTAINER, /repo/…), enquanto o `host_path` de um bind mount é resolvido pelo
# DAEMON (caminho do HOST). Por isso o `TF_VAR_host_repo_root` abaixo: é a
# única forma de o mesmo HCL valer nas duas vias.
#
# NADA disto torna a via 2 segura no sentido forte: quem fala com a API do
# Docker é root no host, e o provider Docker precisa da API INTEIRA — criar
# container é o trabalho dele. O `spc_t` reduz o dano lateral, não o dano. O
# ADR 0003 já tinha registrado essa mesma tensão com o socket na observabilidade.

# Imagem pinada por digest, como toda imagem deste repositório (ADR 0004).
TOFU_IMAGE="${TOFU_IMAGE:-ghcr.io/opentofu/opentofu:1.12.3@sha256:a0766d12f07b43e66f2ed40d7a8babe97d581d20339c68ad0ab561737af9a5b3}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

# Onde o módulo vive e onde o cache de provider fica (fora do diretório de
# trabalho, para o `tofu init` não rebaixar o cache a cada limpeza).
# Qual diretório o tofu trata como módulo raiz, RELATIVO à raiz do repositório.
# O portão troca para `iac/demo-secret` na checagem de vazamento de segredo.
TOFU_SUBDIR="${TOFU_SUBDIR:-iac}"
TOFU_CACHE="${TOFU_CACHE:-$ROOT/iac/.plugin-cache}"

# Qual via esta máquina vai usar. `TOFU_MODE=container` força a via 2 mesmo
# com binário no host — é o que o portão usa para provar as duas.
tofu_mode() {
  if [ "${TOFU_MODE:-auto}" = "container" ]; then echo container; return; fi
  if [ "${TOFU_MODE:-auto}" = "host" ]; then echo host; return; fi
  # `type -P` e NÃO `command -v`: este arquivo define uma FUNÇÃO chamada
  # `tofu` logo abaixo, e o `command -v` acha a função, respondendo "host"
  # numa máquina que não tem o binário. `type -P` só olha o PATH.
  if type -P tofu >/dev/null 2>&1; then echo host; else echo container; fi
}

tofu() {
  mkdir -p "$TOFU_CACHE"
  if [ "$(tofu_mode)" = "host" ]; then
    ( cd "$ROOT/$TOFU_SUBDIR" \
      && TF_PLUGIN_CACHE_DIR="$TOFU_CACHE" \
         TF_ENCRYPTION="${TF_ENCRYPTION:-}" \
         TF_VAR_host_repo_root="$ROOT" \
         command tofu "$@" )
  else
    # O repositório INTEIRO entra, não só o iac/: os contextos de build são o
    # ../stack/services/… e o ../site, e o provider lê o contexto ELE MESMO
    # antes de mandar para o daemon. Com só o iac/ montado, o `filesha256` do
    # Dockerfile já falha.
    #
    # E entra SEM `:z`. O `:z` é um `chcon -R` no que for montado — aqui isso
    # reetiquetaria .git, node_modules e o repositório todo. Não é preciso:
    # medindo, o `spc_t` lê `user_home_t` sem relabel nenhum (o `container_t`
    # padrão não lê). É a vantagem prática de usar o tipo certo em vez do
    # `label=disable`.
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      --group-add "$(stat -c '%g' "$DOCKER_SOCK")" \
      --security-opt label=type:spc_t \
      -v "$DOCKER_SOCK":/var/run/docker.sock \
      -v "$ROOT":/repo \
      -w "/repo/$TOFU_SUBDIR" \
      --tmpfs /tmp:rw,mode=1777 \
      -e TF_PLUGIN_CACHE_DIR=/repo/iac/.plugin-cache \
      -e TF_ENCRYPTION="${TF_ENCRYPTION:-}" \
      -e TF_VAR_host_repo_root="$ROOT" \
      -e TF_IN_AUTOMATION=1 \
      -e HOME=/tmp \
      "$TOFU_IMAGE" "$@"
  fi
}
