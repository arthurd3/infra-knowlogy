# 0011 — Como o agente de build constrói imagens

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

O módulo 3 põe um Jenkins conteinerizado para rodar o pipeline que hoje vive no
GitHub Actions: lint → build → scan → assinatura. O "build" aí é construir as
imagens desta stack — e é onde mora a decisão mais consequente do módulo
inteiro, porque ela define **o que um `RUN` malicioso alcança**.

Num pipeline que constrói pull request, quem abre o PR controla o `Dockerfile`.
O `RUN` dele executa no agente. A pergunta não é acadêmica: é literalmente
"quem abre um PR neste repositório vira root na minha máquina?".

Este ADR foi escrito **depois** de rodar a sonda, não antes. O resultado mudou a
conclusão que o plano previa.

## As opções, e o que cada uma custa neste host

Ambiente medido: Fedora, kernel 7.2.5, **SELinux Enforcing**, Docker 29.7.2
rootful, cgroup v2, `user.max_user_namespaces=127586`, `/dev/fuse` presente.

### (a) bind mount de `/var/run/docker.sock` — recusada

O caminho que todo tutorial mostra. Quem fala com o socket cria um container
`--privileged --pid=host` e sai dele: é **root no host**, não uma aproximação.

E há uma ironia que vira lição: sob SELinux o socket é barrado, e o workaround
de uma linha que se cola da internet — `--security-opt label=disable` — é
justamente a remoção da última barreira. O ADR 0003 já registrou essa tensão na
observabilidade; repeti-la no módulo que ensina automação seria o repositório se
contradizendo.

### (b) Docker-in-Docker com `--privileged` — recusada

Troca o socket por um daemon privilegiado. `--privileged` roda o container como
`spc_t`: o confinamento SELinux não é enfraquecido, ele **deixa de existir**.
Acrescenta storage driver aninhado e um terceiro cache de build, e não melhora o
modelo de ameaça.

### (c) Kaniko — recusada

O `GoogleContainerTools/kaniko` foi arquivado pelo Google em junho de 2025 (há
um fork mantido pela Chainguard). Escolher um builder arquivado no módulo que
ensina cadeia de suprimentos é indefensável.

### (d) BuildKit rootless — **escolhida**

## A decisão, e a descoberta

`moby/buildkit:rootless`, com o agente falando com ele por socket Unix num
volume compartilhado. O agente não tem docker CLI, não tem socket, não é
privilegiado.

A receita oficial pede três `unconfined`:

```
--security-opt seccomp=unconfined      # unshare/mount para o runc
--security-opt apparmor=unconfined     # no-op no Fedora (não há AppArmor)
--security-opt systempaths=unconfined  # /proc próprio em cada RUN
```

Nenhum deles é privilégio de root, e a documentação é explícita em dizer que
são seguros **porque o buildkitd não é root**. Medido aqui: `systempaths` é
repassado de verdade (`MaskedPaths=[]`, `ReadonlyPaths=[]`).

Com esses três e mais nada, sob SELinux Enforcing, o `RUN` falha:

```
error mounting "proc" to rootfs at "/proc": ... permission denied
```

O plano previa uma escada de fallback terminando em `label=disable`. **Ela não
foi necessária.** O Fedora tem um tipo SELinux feito exatamente para engine de
container aninhada, e ele resolve mantendo o confinamento:

```
--security-opt label=type:container_engine_t
```

Provado por experimento controlado, com `getenforce` = Enforcing o tempo todo:

| `--security-opt` | rótulo do processo | build |
|---|---|---|
| (padrão) | `container_t:s0:c33,c459` | **falha** no mount de `/proc` |
| `label=disable` | *(vazio — sem confinamento)* | passa |
| `label=type:container_engine_t` | `container_engine_t:s0:c216,c785` | **passa, confinado** |

O rótulo com categorias MCS é a prova de que não houve fallback silencioso.

## Como isso foi verificado

`make cicd-prereqs` roda a sonda, e ela constrói uma fixture com um `RUN` de
verdade — sem o `RUN`, `/proc` não é montado e a sonda mentiria.

A prova que fecha o argumento é outra: a stack inteira do `api-go` construída
pelos dois caminhos, e o binário Go comparado byte a byte.

| | `docker build` | BuildKit rootless |
|---|---|---|
| sha256 do `/api-go` | `2859240b1b319ff7…` | `2859240b1b319ff7…` |
| tamanho | 14.762.168 B | 14.762.168 B |
| camadas | 13 | 13 |
| `User` / `Entrypoint` | `65532:65532` / `["/api-go"]` | idênticos |
| tempo, cache frio | — | **25 s** |

Mesmo artefato. O caminho sem daemon não é uma aproximação do build de verdade;
é o mesmo build, com outro executor.

## Consequências

**A favor:**

- O processo que executa `RUN` controlável por terceiro **não é root no host** e
  continua confinado pelo SELinux. O raio de explosão deixa de ser "a máquina" e
  passa a ser "um container rootless".
- O repositório fica coerente: o ADR 0003 recusou o socket, o `scan.sh` evita o
  socket escaneando um tarball, o OWASP diz o mesmo.
- Continuidade com o módulo 1: BuildKit é o que o `docker build` desta máquina
  já usa. Mesmos Dockerfiles, mesma semântica de multi-stage, mesmo resultado.
- O BuildKit tem **entitlements**: `security.insecure` e `network.host` só valem
  se o daemon subir com `--allow-insecure-entitlement`. Nós não habilitamos, e o
  portão vai provar que um build que os pede é recusado.

**Contra, e assumido:**

- **Cache separado.** O store do buildkitd rootless não é o do dockerd do host;
  a primeira execução é fria. Mitigado com volume nomeado, e o frio × quente
  vira número de lição.
- **Um round-trip de tarball por imagem** (`type=docker,dest=` → `docker load`).
  É o mesmo padrão que o `scan.sh` já usa, então não é conceito novo.
- **`container_engine_t` é específico do Fedora/RHEL.** Num host Debian sem essa
  política, a sonda cai no degrau seguinte e avisa. O script trata os três casos.
- **Três `unconfined` ainda são três.** Menos que `--privileged` e mais que zero.
  A lição 4 do módulo vai mostrar exatamente o que cada um libera, em vez de
  pedir confiança.

## O que continua sendo demonstrado

A escolha não apaga o caminho ruim — ela o usa. O escape via `docker.sock` é
demonstrável em dois comandos e vira exercício da lição 4, com a saída gravada,
junto com a checagem negativa do portão: *o agente não enxerga o socket*.
