#!/usr/bin/env bash
# Faz o inbound-agent respeitar a convenção `<VAR>_FILE` deste repositório.
#
# O entrypoint de cima aceita `JENKINS_SECRET` com o VALOR na variável de
# ambiente, e só. Este repositório não faz isso em lugar nenhum: o config.go e
# o config.py leem `<VAR>_FILE` apontando para /run/secrets/, porque variável
# de ambiente vaza em `docker inspect`, no `/proc/<pid>/environ` de quem
# estiver no mesmo namespace, e em todo log que despeja o ambiente.
#
# Seis linhas para não abrir exceção à regra. A alternativa era escrever
# "menos aqui" numa convenção de segurança, que é como convenção morre.
set -euo pipefail

if [ -n "${JENKINS_SECRET_FILE:-}" ]; then
  [ -r "$JENKINS_SECRET_FILE" ] || { echo "não consigo ler $JENKINS_SECRET_FILE" >&2; exit 1; }
  JENKINS_SECRET="$(cat "$JENKINS_SECRET_FILE")"
  export JENKINS_SECRET
  unset JENKINS_SECRET_FILE
fi

exec /usr/local/bin/jenkins-agent "$@"
