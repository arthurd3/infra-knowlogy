# syntax=docker/dockerfile:1
#
# worker-py — o idioma multi-stage do Python, que é diferente do Go.
#
# No Go o artefato é UM binário estático e a imagem final pode ser `scratch`.
# Em Python o artefato é um interpretador + uma árvore de dependências, então a
# imagem final ainda precisa de um Python. O que a stage de build descarta é o
# uv, o cache de wheels e qualquer toolchain de compilação.
#
#   --target dist     produção: python slim + venv, sem uv        (~130 MB)
#   --target fat      antipadrão didático: tudo numa stage só      (~250 MB)
#
# `tools/scripts/sizes.sh` builda os dois para a lição mostrar a diferença medida.

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: build — instala as dependências numa venv isolada
# ─────────────────────────────────────────────────────────────────────────────
FROM ghcr.io/astral-sh/uv:0.9-python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca AS build

# UV_COMPILE_BYTECODE gera os .pyc no BUILD. Sem isso o Python os escreveria no
# primeiro import em produção — o que falha silenciosamente num rootfs read-only
# e adiciona latência ao primeiro request de cada container novo.
# UV_LINK_MODE=copy: o padrão é hardlink, que não atravessa a fronteira entre o
# cache montado e a camada da imagem.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Duas invocações do uv de propósito. Esta primeira instala SÓ as dependências
# de terceiros, montando apenas o lockfile e o pyproject. Como o código-fonte
# ainda não entrou, editar worker/main.py não invalida esta layer — e é ela que
# custa os segundos de download e de build de wheel.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

# Agora sim o código. Esta é a layer que muda a cada commit — e é barata.
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: dist — runtime de produção
# ─────────────────────────────────────────────────────────────────────────────
# Mesma distribuição e mesma minor version do Python da stage de build. Se
# divergissem, as wheels compiladas (psycopg-binary traz .so em C) quebrariam
# com "undefined symbol" em runtime — não no build, o que é bem pior.
FROM python:3.13-slim-bookworm@sha256:c45a22ea000adfd9cda29364bbe7edd23001ce5cc2ad15857cfbf7766943b9ca AS dist

# PYTHONUNBUFFERED é obrigatório em container: sem ele o stdout do Python é
# bufferizado em blocos de 8 KB quando não é um TTY, e os logs só aparecem
# minutos depois — ou nunca, se o processo morrer com o buffer cheio.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# UID/GID explícitos e fixos. Sem o número, o UID depende de quantos usuários a
# imagem base já tinha — e muda quando a base muda, quebrando a permissão de
# qualquer volume que já existia.
RUN groupadd --gid 65532 app \
    && useradd --uid 65532 --gid 65532 --no-log-init --create-home --shell /usr/sbin/nologin app \
    # Remove o pip da imagem de RUNTIME. A aplicação roda de uma venv já pronta
    # e nunca instala nada em produção — mas o pip vendoriza cópias próprias de
    # setuptools e msgpack, e eram elas que apareciam no scanner de CVE.
    #
    # Nota honesta: isto tira os arquivos do sistema de arquivos final (e do
    # relatório do Trivy, que analisa a imagem achatada), mas NÃO diminui o
    # tamanho do download — os bytes continuam na camada da imagem base, pelo
    # mesmo motivo pelo qual uma camada nunca encolhe. O ganho aqui é de
    # superfície de ataque, não de tamanho.
    && rm -rf /usr/local/lib/python3.13/site-packages/pip \
              /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
              /usr/local/bin/pip /usr/local/bin/pip3*

WORKDIR /app
# --chown no COPY evita um `RUN chown -R` depois, que duplicaria a árvore inteira
# numa layer nova (a layer antiga continua na imagem — chown não apaga nada).
COPY --from=build --chown=65532:65532 /app /app

LABEL org.opencontainers.image.title="infra-knowlogy worker-py" \
      org.opencontainers.image.description="Worker de enriquecimento de links" \
      org.opencontainers.image.source="https://github.com/infra-knowlogy/infra-knowlogy" \
      org.opencontainers.image.licenses="MIT"

USER 65532:65532
EXPOSE 9100

# Mesmo truque do Go: o health check usa o runtime que JÁ está na imagem em vez
# de instalar curl. Aqui o runtime é o próprio Python.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=3).status==200 else 1)"]

# Exec form: o processo Python vira PID 1 e recebe o SIGTERM diretamente.
ENTRYPOINT ["python", "-m", "worker.main"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: fat — o antipadrão, para a lição ter um "antes"
# ─────────────────────────────────────────────────────────────────────────────
# Uma stage só: o uv, o cache e o toolchain ficam todos na imagem final. Roda
# igual — e é por isso que o antipadrão sobrevive tanto tempo em produção.
FROM ghcr.io/astral-sh/uv:0.9-python3.13-bookworm-slim@sha256:531f855bda2c73cd6ef67d56b733b357cea384185b3022bd09f05e002cd144ca AS fat
WORKDIR /app
COPY . /app
RUN uv sync --locked --no-dev
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-m", "worker.main"]
