# syntax=docker/dockerfile:1
#
# api-go — três alvos de produção no MESMO Dockerfile, de propósito.
#
#   --target dist     imagem padrão: distroless static, nonroot  (~13 MB)
#   --target minimal  scratch puro, montado à mão                (~10 MB)
#   --target debug    alpine, tem shell — para quando algo quebra (~18 MB)
#
# Os três compartilham a MESMA stage de build, então comparar os tamanhos
# compara só a base — que é exatamente o ponto da lição sobre imagens base.
# `tools/scripts/sizes.sh` builda os três e grava os números medidos.

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: build
# ─────────────────────────────────────────────────────────────────────────────
# Pinado por digest, não só por tag: uma tag é um ponteiro mutável e `golang:1.25-alpine`
# aponta para uma imagem diferente a cada semana. O digest torna o build reprodutível.
# `make pins` atualiza esta linha.
FROM golang:1.25-alpine@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59 AS build

WORKDIR /src

# Dependências antes do código-fonte. go.mod/go.sum mudam raramente; os .go
# mudam a cada commit. Nesta ordem, editar um handler NÃO refaz o download de
# todos os módulos — a regra de ouro do cache de build.
#
# --mount=type=bind evita COPY: os arquivos ficam visíveis durante o RUN e não
# viram uma layer. --mount=type=cache preserva o cache de módulos ENTRE builds,
# algo que uma layer não consegue fazer.
RUN --mount=type=bind,source=go.mod,target=go.mod \
    --mount=type=bind,source=go.sum,target=go.sum \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

# Só agora o código-fonte entra.
COPY . .

# CGO_ENABLED=0 é o que torna o binário estático — sem ele o Go linka contra a
# libc do Alpine (musl) e o binário morre com "no such file or directory" numa
# imagem scratch, que não tem libc nenhuma.
#
# -trimpath remove os caminhos absolutos da máquina de build (reprodutibilidade
# e menos vazamento de informação). -w -s descartam DWARF e a tabela de símbolos,
# ~25% do tamanho do binário.
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build -trimpath -ldflags="-w -s" -o /out/api-go .

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2a: dist — o alvo padrão de produção
# ─────────────────────────────────────────────────────────────────────────────
# distroless/static traz o mínimo que um binário estático realmente precisa e
# que o scratch NÃO tem: certificados CA, tzdata, /etc/passwd com o usuário
# nonroot (uid 65532) e um /tmp. Sem shell, sem gerenciador de pacotes:
# um invasor que consiga execução de comando não tem com o que trabalhar.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS dist

COPY --from=build /out/api-go /api-go

# Metadados OCI padronizados — é assim que registries, scanners e o `docker
# scout` descobrem a origem da imagem.
LABEL org.opencontainers.image.title="infra-knowlogy api-go" \
      org.opencontainers.image.description="API do encurtador de links da stack de referência" \
      org.opencontainers.image.source="https://github.com/infra-knowlogy/infra-knowlogy" \
      org.opencontainers.image.licenses="MIT"

# A imagem distroless:nonroot já define USER 65532, mas declaramos explicitamente:
# o comportamento passa a não depender de um detalhe da imagem base mudar.
USER 65532:65532
EXPOSE 8080

# O health check chama o PRÓPRIO binário — não existe curl aqui dentro.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/api-go", "healthcheck"]

# Exec form (JSON array). Na shell form o processo viraria filho de `/bin/sh -c`,
# o shell seria o PID 1, e o SIGTERM do `docker stop` morreria nele em vez de
# chegar na aplicação — o container só sairia no SIGKILL, 10 segundos depois.
ENTRYPOINT ["/api-go"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2b: minimal — scratch de verdade, para a lição
# ─────────────────────────────────────────────────────────────────────────────
# `scratch` é a imagem vazia: zero byte, zero arquivo. Tudo que o processo
# precisa tem que ser copiado à mão — e é justamente por isso que ela ensina
# o que uma imagem base realmente fornece.
FROM scratch AS minimal

# Sem isto, QUALQUER requisição HTTPS de dentro do container falha com
# "x509: certificate signed by unknown authority". É a pegadinha nº 1 do scratch.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
# Sem /etc/passwd, `USER nonroot` nem resolve — só UID numérico funcionaria.
COPY --from=build /etc/passwd /etc/passwd
COPY --from=build /out/api-go /api-go

USER 65534:65534
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/api-go", "healthcheck"]
ENTRYPOINT ["/api-go"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2c: debug — mesma aplicação, com shell
# ─────────────────────────────────────────────────────────────────────────────
# Serve para quando você PRECISA de um `docker exec ... sh` para investigar.
# Nunca é o alvo padrão: o shell e o apk que a tornam útil para você também a
# tornam útil para quem invadir.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS debug

# Trade-off honesto sobre pinar versão de pacote no Alpine: os repositórios do
# Alpine só carregam a versão ATUAL de cada pacote. Um pin exato como este
# quebra o build no dia em que o upstream publicar a próxima — o digest do
# `FROM` acima é que garante a reprodutibilidade de verdade. Mantemos o pin
# porque ele documenta o que foi testado e falha alto em vez de mudar calado.
RUN apk add --no-cache ca-certificates=20260611-r0 \
    && adduser -D -u 65532 app
COPY --from=build /out/api-go /api-go
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/api-go", "healthcheck"]
ENTRYPOINT ["/api-go"]
