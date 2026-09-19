# Módulo 3 — CI/CD self-hosted

O mesmo pipeline que `.github/workflows/ci.yml` roda no GitHub Actions, rodando
num Jenkins que é seu. A aplicação é a de sempre: os três Dockerfiles de
`stack/services/` e `site/`.

```bash
make cicd-prereqs   # checa o host e prova que dá para construir sem daemon
make cicd-up        # sobe controller, buildkitd, agente, scm e registry
make cicd-verify    # o portão — 35 checagens. Estado bom: 35 passaram · 0 falharam
make cicd-down      # derruba (mantém os volumes)
make cicd-nuke      # derruba E apaga os volumes
```

O Jenkins fica em <http://localhost:8090>. Usuário `admin`; a senha é gerada na
primeira subida e fica em `cicd/secrets/jenkins_admin_password`.

## O que sobe

| serviço | o que é | por quê |
|---|---|---|
| `controller` | Jenkins LTS, configurado por JCasC | **0 executores**: ele agenda e guarda credencial, não constrói |
| `buildkitd` | BuildKit rootless | constrói imagem sem daemon e sem privilégio ([ADR 0011](../docs/adr/0011-como-o-agente-de-build-constroi-imagens.md)) |
| `agent` | agente inbound, por WebSocket | **sem docker CLI e sem socket** — é o ponto |
| `scm` | `git daemon` somente-leitura | o plugin git recusa remote local, e ele está certo |
| `registry` | registry local | para onde o pipeline publica |

## As três coisas que este módulo prova

**O controller não constrói nada.** Built-in com 0 executores, porta TCP de
agente desligada (`-1`), agente conectado por WebSocket. Um build que rodasse
no controller teria o mesmo acesso ao disco que o processo do Jenkins — logo,
às credenciais dele.

**O agente não é root no host.** Sem `/var/run/docker.sock`, sem o binário
`docker`, sem privilégio, e o construtor ainda confinado pelo SELinux como
`container_engine_t`. Um `RUN` vindo de um pull request aberto executa ali: o
raio de explosão é um container rootless, não a máquina.

**O artefato é o mesmo.** O binário Go que sai do pipeline é byte a byte igual
ao do `docker build` local. O caminho sem daemon não é uma aproximação.

## Iterar rápido

```bash
KEEP_JENKINS=1 SKIP_BUILD=1 SKIP_NEGATIVE=1 make cicd-verify
```

`SKIP_BUILD=1` pula o pipeline completo (o mais caro), `SKIP_NEGATIVE=1` pula a
prova de que ele reprova, `SKIP_REPRO=1` pula a comparação com o build local, e
`KEEP_JENKINS=1` deixa tudo no ar.

## Mexer nos plugins

```bash
make cicd-plugins   # reescreve plugins.txt com o fecho transitivo pinado
make cicd-verify
```

Os plugins de primeiro nível ficam no topo de
`tools/scripts/update-jenkins-plugins.sh` — eles são a **decisão**. O
`plugins.txt` é o **resultado**: as 67 linhas do fecho transitivo, todas
pinadas, porque pinar só a decisão e deixar as dependências soltas é pin
decorativo.

## O pipeline

`lint → build → scan → sign → verify → archive`, tudo pelo `buildctl`, sem
daemon em lugar nenhum.

O `sign` é onde a assimetria com o GitHub Actions aparece: lá a assinatura é
**keyless** — a identidade é o token OIDC do próprio workflow e não existe
chave privada para guardar. Aqui ela custa exatamente um par de chaves que
alguém precisa gerar, proteger e rotacionar. O `cicd-up.sh` gera; num ambiente
de verdade a chave vive num KMS.

E o `verify` existe porque assinar sem verificar é fé: o pipeline prova a
própria assinatura antes de chamar o artefato de confiável.
