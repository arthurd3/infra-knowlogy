# O hadolint rodando DENTRO do builder, porque o agente não tem docker.
#
# O `make lint` do módulo 1 faz `docker run hadolint`. Aqui não há daemon para
# isso — e a saída não é instalar um, é lembrar que o builder executa
# qualquer coisa: um estágio que falha reprova o build, e é exatamente o que
# um lint precisa fazer.
#
# Construído com o repositório inteiro como contexto.
FROM hadolint/hadolint:v2.14.0-alpine@sha256:7aba693c1442eb31c0b015c129697cb3b6cb7da589d85c7562f9deb435a6657c

# DL4006: sem isto, `find … | xargs hadolint` tem sucesso mesmo quando o
# `find` falha — o shell só olha o último comando do pipe. É a mesma regra que
# a lição 3 ensina, e o lint a cobrou de nós.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

WORKDIR /work
COPY . /work

# `find -print0`/`xargs -0` porque caminho com espaço existe. O `|| exit 1` é
# redundante com `set -e`, mas deixa explícito que este RUN é o portão.
# A fixture NEGATIVA fica de fora por padrão: ela viola hadolint de propósito,
# e incluí-la faria o pipeline bom falhar sempre.
#
# É ARG e não ENV para o pipeline negativo poder passar EXCLUDES vazio e
# INCLUIR a fixture ruim. Assim a prova negativa usa a MESMA imagem, a MESMA
# regra e o MESMO hadolint — muda um argumento. Sem isso, o negativo provaria
# que outro arquivo falha, e não que este lint recusa.
ARG EXCLUDES="-not -path ./node_modules/* -not -path ./*/node_modules/* -not -path ./cicd/fixtures/bad/*"

RUN set -eu; \
    echo "── Dockerfiles encontrados:"; \
    find . -name Dockerfile $EXCLUDES -print; \
    find . -name Dockerfile $EXCLUDES -print0 \
      | xargs -0 -r hadolint --no-color
