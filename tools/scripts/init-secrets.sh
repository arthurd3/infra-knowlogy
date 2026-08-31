#!/usr/bin/env bash
# Gera stack/.env e os arquivos de segredo locais.
#
# Idempotente de propósito: NUNCA sobrescreve um arquivo que já existe. Trocar a
# senha aqui depois que o volume do Postgres já foi inicializado não muda a senha
# no banco — só quebra a conexão de todo mundo.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/stack"
SECRETS="$STACK/secrets"

if [[ ! -f "$STACK/.env" ]]; then
  cp "$STACK/.env.example" "$STACK/.env"
  echo "  criado stack/.env"
fi

# O diretório é 0700: nenhum outro usuário do host consegue sequer entrar nele.
# É aqui que mora a proteção real — ver a nota sobre o modo dos arquivos abaixo.
mkdir -p "$SECRETS"
chmod 700 "$SECRETS"

gen_secret() {
  local name="$1" path="$SECRETS/$1"
  if [[ ! -f "$path" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -base64 32 | tr -d '\n' > "$path"
    else
      head -c 32 /dev/urandom | base64 | tr -d '\n' > "$path"
    fi
    echo "  gerado stack/secrets/$name"
  fi

  # 0444 e não 0400. Motivo concreto: o Compose (fora do Swarm) faz BIND MOUNT
  # do arquivo como ele está no host — os campos `uid`, `gid` e `mode` da
  # Compose Specification só são honrados pelo Swarm. E três serviços leem este
  # mesmo arquivo com UIDs diferentes: api e worker como 65532, postgres-exporter
  # como nobody. Um arquivo 0400 do dono uid 1000 é ilegível para todos eles.
  #
  # A proteção não vem do modo do arquivo, e sim do 0700 no diretório acima.
  # Em produção de verdade isto é trabalho de um cofre (Vault, SOPS, o secret
  # store da nuvem) ou de secrets de Swarm/Kubernetes, que resolvem uid/gid.
  chmod 444 "$path"
}

gen_secret postgres_password
gen_secret grafana_password

# SELinux: `secrets:` NÃO aceita o sufixo `:z` que os volumes aceitam, então o
# arquivo mantém o rótulo do host (user_home_t) e o container recebe
# "Permission denied" — mesmo com o arquivo world-readable e o processo como
# root. Rotulamos à mão. Sem isto, o Postgres entra em loop de restart no
# Fedora/RHEL/CentOS com uma mensagem que não menciona SELinux em momento algum.
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  if command -v chcon >/dev/null 2>&1; then
    chcon -Rt container_file_t "$SECRETS" 2>/dev/null \
      && echo "  rótulo SELinux container_file_t aplicado em stack/secrets/" \
      || echo "  ⚠ não consegui rotular stack/secrets/ para o SELinux" >&2
  fi
fi

echo "segredos prontos."
