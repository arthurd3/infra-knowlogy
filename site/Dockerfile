# syntax=docker/dockerfile:1
#
# site — o terceiro idioma de multi-stage, e o mais claro dos três.
#
# Go produz um binário. Python produz uma venv. Node produz... nada que precise
# de Node. O `astro build` gera HTML, CSS e JS estáticos; depois disso o Node,
# o npm e as 442 dependências de desenvolvimento não têm mais nenhuma função.
# A imagem final é um servidor de arquivos com os arquivos dentro.
#
#   --target dist  produção: Caddy + HTML estático  (~55 MB, zero Node)
#   --target dev   desenvolvimento: Node + astro dev com hot reload
#
# Este Dockerfile serve o site que explica este Dockerfile.

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: deps — só as dependências
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS deps
WORKDIR /app

# Stage separada só para as dependências. package.json e package-lock.json mudam
# raramente; src/ muda a cada frase escrita numa lição. Assim, editar uma lição
# não refaz o `npm ci`.
#
# `npm ci` e não `npm install`: ci instala EXATAMENTE o que está no lockfile e
# falha se package.json e lockfile divergirem. `install` atualiza o lockfile
# silenciosamente, e aí o build deixa de ser reprodutível.
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=package-lock.json,target=package-lock.json \
    --mount=type=cache,target=/root/.npm \
    npm ci --include=dev

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: build — gera o site estático
# ─────────────────────────────────────────────────────────────────────────────
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS build
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: dist — produção
# ─────────────────────────────────────────────────────────────────────────────
# Nada de Node aqui. Só o Caddy e os arquivos gerados. Isto é multi-stage no seu
# melhor: a stage de build tinha ~500 MB de toolchain, e nada disso sobrevive.
FROM caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648 AS dist

# A tag caddy:2-alpine mais recente ainda traz curl, openssl e c-ares com CVE
# corrigida a montante. Aplicar os patches do Alpine por cima é o conserto
# disponível enquanto o mantenedor não republica a imagem.
#
# O custo é real e vale dizer: isto afrouxa a reprodutibilidade que o digest do
# FROM garante — dois builds do mesmo commit em datas diferentes podem trazer
# versões de pacote diferentes. Trocamos um pouco de reprodutibilidade por
# imagem sem CVE conhecida, e é uma troca deliberada, não um descuido.
RUN apk --no-cache upgrade

COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/dist /srv

LABEL org.opencontainers.image.title="infra-knowlogy site" \
      org.opencontainers.image.description="Site bilíngue de lições de infraestrutura" \
      org.opencontainers.image.source="https://github.com/infra-knowlogy/infra-knowlogy" \
      org.opencontainers.image.licenses="MIT"

EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD ["wget", "--quiet", "--spider", "http://127.0.0.1:8080/"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4: dev — servidor de desenvolvimento
# ─────────────────────────────────────────────────────────────────────────────
# Usada só por compose.dev.yaml. Tem o Node inteiro porque `astro dev` precisa
# dele; o hot reload chega via `develop.watch` do Compose sincronizando src/.
FROM node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS dev
WORKDIR /app
ENV NODE_ENV=development
COPY --from=deps /app/node_modules ./node_modules
COPY . .
EXPOSE 8080
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "8080"]
