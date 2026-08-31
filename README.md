# infra-knowlogy — Módulo 1: Docker

> **Uma stack Docker de produção que roda de verdade — e as lições que explicam
> cada decisão dela.**
> *A production Docker stack that actually runs — and the lessons explaining every
> decision in it.* → [English below](#english)

O princípio que amarra o repositório inteiro: **as lições ensinam exatamente o
código que está aqui, com números medidos nesta máquina.** Nada de exemplo
genérico de blog. Quando a lição sobre imagens base mostra uma tabela de
tamanhos, aqueles bytes saíram de `docker image inspect` rodado sobre estes
Dockerfiles, por `tools/scripts/sizes.sh`.

E o site que ensina o Dockerfile multi-stage é servido pelo próprio Dockerfile
multi-stage que ele explica.

## Comece por aqui

```bash
make            # lista tudo que dá para fazer
make up         # sobe a stack endurecida e espera todos os healthchecks
make site-dev   # abre as lições em http://localhost:4321
make verify     # o portão de qualidade: builda, sobe, testa e prova o endurecimento
```

Requisitos: Docker 25+ com BuildKit, Docker Compose v2+, Node 22+ (só para o
site), e `uv` (só para `make index`). Testado em Fedora com SELinux ativo.

## A stack

Um encurtador de links com enriquecimento assíncrono. Pequeno o bastante para ser
lido inteiro, completo o bastante para exercitar tudo que as lições precisam
ensinar.

```
                    127.0.0.1:8080
                          │
                    ┌─────▼─────┐
                    │   edge    │  Caddy · TLS automático · sem acesso ao socket
                    └──┬─────┬──┘
              rede edge │     │
                 ┌──────▼─┐ ┌─▼──────┐
                 │  web   │ │  api   │  Go · distroless · 5,7 MB
                 └────────┘ └───┬────┘
                                │  rede data (internal: true — SEM saída)
                      ┌─────────┼─────────┐
                 ┌────▼───┐ ┌───▼────┐ ┌──▼─────┐
                 │   db   │ │ cache  │ │ worker │  Python · uv · 49,9 MB
                 └────────┘ └────────┘ └───┬────┘
                  Postgres    Redis        │ rede egress
                                           ▼ busca URLs (com defesa contra SSRF)
```

Repare no desenho de rede: `db` e `cache` estão **somente** na rede `data`, que é
`internal: true` — eles não têm rota para a internet, e o proxy literalmente não
consegue alcançá-los. O `worker` é a exceção estudada, porque precisa buscar URLs
enviadas por usuários; por isso o código dele tem a checagem de SSRF.

| Serviço | Linguagem | Imagem final | O que ele ensina |
|---|---|---|---|
| `api-go` | Go | 5,7 MB (distroless) | binário estático, `scratch`, CA certs, shutdown gracioso |
| `worker-py` | Python | 49,9 MB (slim + venv) | multi-stage com `uv`, SIGTERM em loop, SSRF |
| `web` | Node → estático | 26,2 MB (Caddy) | build que descarta o próprio runtime |
| `edge` | — | Caddy | proxy reverso sem tocar o socket do Docker |
| `db` / `cache` | — | Postgres 17 / Redis 7 | volumes, healthcheck, `service_healthy` |

Com `make obs`, somam-se Prometheus, Grafana, Loki, Alloy, cAdvisor,
node-exporter e dois exporters — atrás do profile `obs`, para que o dia a dia
continue subindo em segundos.

## As lições

16 lições — 8 assuntos, em português e inglês — em `site/src/content/lessons/`,
com três widgets interativos que rodam inteiramente no navegador.

**Trilha Fundamentos:** o que um container realmente é · imagens, camadas e
digests · o Dockerfile instrução por instrução · o cache de build · ciclo de vida
e códigos de saída · volumes, bind mounts e tmpfs · redes e DNS interno · Compose
e healthchecks.

Cada lição termina com um bloco **"Rode você mesmo"** — comandos reais contra a
stack deste repositório, não pseudocódigo.

Algumas afirmações foram **medidas e corrigiram o senso comum**. Por exemplo: a
explicação difundida de que a shell form do `CMD` quebra o `docker stop` está
incompleta — o BusyBox faz `exec` de comando simples, e o `sleep` vira PID 1 de
qualquer jeito. A causa real é que **o kernel não aplica ações padrão de sinal ao
PID 1**. A tabela na lição 3 traz os quatro casos cronometrados.

## Verificação

`make verify` roda nove etapas e falha alto. Ele não checa só que o código
compila — ele **prova as afirmações das lições**:

- `hadolint` em todo Dockerfile e `config -q` nas três combinações de Compose;
- build de tudo, e regravação dos tamanhos medidos em `measured.json`;
- `up --wait`, que só passa se todos os healthchecks passarem;
- smoke test do fluxo: criar link → redirect 302 → o worker enriquece → **uma URL
  interna é recusada pela defesa contra SSRF**;
- provas de endurecimento: escrita em `/` **falha**, `/tmp` funciona, uid é
  65532, não há porta em `0.0.0.0`, o segredo não está no `docker history` nem em
  `env`, e o `edge` **não alcança** o `db`;
- desligamento gracioso — falha se qualquer serviço demorar mais de 3 s;
- Trivy falhando em HIGH/CRITICAL, com SBOM em CycloneDX;
- build do site e **paridade PT/EN** (nenhuma lição pode existir num idioma só);
- com o profile `obs`, todos os alvos do Prometheus precisam estar `up`.

## Estrutura

```
stack/          código de produção: compose + services/{api-go,worker-py,edge,db,observability}
site/           o site bilíngue de lições (Astro + MDX + ilhas React)
tools/scripts/  verify · sizes · scan · shutdown-test · update-pins · index-qdrant
docs/adr/       por que Compose e não k8s, por que Caddy e não Traefik, e o resto
```

Decisões e alternativas recusadas estão em [`docs/adr/`](docs/adr/) — escritas só
em português, por serem notas internas de engenharia e não material didático.

---

<a name="english"></a>

# infra-knowlogy — Module 1: Docker

**A production Docker stack that actually runs — and the lessons explaining every
decision in it.**

The principle tying the whole repository together: **the lessons teach exactly the
code that is here, with numbers measured on this machine.** No generic blog
examples. When the base-image lesson shows a size table, those bytes came from
`docker image inspect` run against these Dockerfiles by `tools/scripts/sizes.sh`.

And the site teaching multi-stage builds is served by the very multi-stage
Dockerfile it explains.

## Start here

```bash
make            # list everything you can do
make up         # bring up the hardened stack and wait for every healthcheck
make site-dev   # open the lessons at http://localhost:4321
make verify     # the quality gate: build, boot, test, and prove the hardening
```

Requirements: Docker 25+ with BuildKit, Docker Compose v2+, Node 22+ (site only),
and `uv` (for `make index` only). Tested on Fedora with SELinux enforcing.

## The stack

A link shortener with asynchronous enrichment — small enough to read end to end,
complete enough to exercise everything the lessons need to teach. See the diagram
above: `db` and `cache` live **only** on the `data` network, which is
`internal: true`, so they have no route to the internet and the proxy cannot reach
them at all. `worker` is the studied exception, since it fetches user-submitted
URLs — which is why its code carries an SSRF guard.

Three languages on purpose, because they produce three genuinely different
Dockerfile idioms: Go ships one static binary (the final image can be `scratch`),
Python ships an interpreter plus a venv (the final image still needs a runtime),
and Node ships static HTML (**the final image needs no Node at all**).

## The lessons

16 lessons — 8 topics, in Portuguese and English — under
`site/src/content/lessons/`, with three interactive widgets that run entirely in
the browser. Every lesson ends with a **"Run it yourself"** block containing real
commands against this repository's stack.

Some claims were **measured and corrected common wisdom**. For instance, the
widespread explanation that `CMD`'s shell form breaks `docker stop` is
incomplete — BusyBox `exec`s a simple command, so `sleep` becomes PID 1 either
way. The real cause is that **the kernel applies no default signal dispositions to
PID 1**. Lesson 3 carries all four cases, timed.

## Verification

`make verify` runs nine stages and fails loudly. It does not merely check that
code compiles — it **proves the lessons' claims**: writing to `/` must fail, the
declared tmpfs must work, the uid must be 65532, no port may be bound to
`0.0.0.0`, the secret must appear in neither `docker history` nor `env`, `edge`
must not reach `db`, every service must stop in under 3 seconds, and an internal
URL must be rejected by the SSRF guard.

## License

MIT.
