# 0016 — Como o `tofu` alcança o daemon, e o que isso custa

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O provider Docker do módulo 4 precisa falar com `/var/run/docker.sock`. Isso
repete a tensão do [ADR 0003](0003-socket-do-docker-na-observabilidade.md) —
quem fala com o socket é root no host — com um agravante: lá o Alloy só
precisava **ler** `/containers`, e por isso coube um proxy com allowlist. Aqui
não cabe. **Criar container é o trabalho do provider**; ele precisa da API
inteira, e uma allowlist que permita `POST /containers/create` já entregou tudo.

Como no ADR 0011, este documento foi escrito **depois** da sonda, e o resultado
mudou o que o plano previa.

## A medição

Fedora, SELinux **Enforcing**, Docker 29.7.2 rootful. O socket é
`srw-rw---- root:docker`, rótulo `system_u:object_r:container_var_run_t:s0`.
O `dockerd` do host roda como **`container_runtime_t`**.

A sonda (`tools/scripts/iac-prereqs.sh`) faz um `connect()` de verdade — um
`GET /_ping` pelo socket — porque o que o SELinux barra é a conexão, não o
mount. Um `ls` passaria e mentiria.

| `--security-opt` | rótulo real do processo | MCS | `connect()` |
|---|---|---|---|
| *(padrão)* | `container_t:s0:c948,c1019` | sim | **negado** |
| `label=type:container_engine_t` | `container_engine_t:s0:c431,c570` | sim | **negado** |
| `label=type:spc_t` | `spc_t:s0:c55,c466` | **sim** | OK |
| `label=disable` | `spc_t:s0` | **não** | OK |

Três coisas saem daí, e nenhuma era esperada.

### 1. O `container_engine_t` NÃO resolve o socket do Docker

O módulo 3 descobriu (armadilha 22) que o Fedora tem um tipo feito para engine
de container aninhada, e que ele resolvia o socket do **buildkitd** mantendo o
confinamento. A conclusão natural — "use `container_engine_t` para qualquer
socket de engine" — está **errada**, e a armadilha 23 já dizia por quê sem que
ninguém tivesse ligado os pontos: o SELinux avalia `connectto` contra o
**processo que escuta**, não contra o rótulo do arquivo. O buildkitd escuta
como container; o `dockerd` escuta como `container_runtime_t`. São alvos
diferentes, e a política que cobre um não cobre o outro.

Por isso a armadilha 7 (*"para o `docker.sock`, só `label=disable` resolve"*)
continua de pé — ela só estava incompleta.

### 2. `label=disable` não desliga o SELinux: ele entrega `spc_t` sem MCS

É a parte que muda o conselho. O workaround colado de todo tutorial e o pedido
explícito `label=type:spc_t` produzem **o mesmo tipo**. A diferença está nas
**categorias MCS**: o `disable` sai com `s0` puro, o pedido explícito sai com
`s0:c55,c466`.

MCS é o que impede um container de tocar nos arquivos rotulados de **outro**
container. Com `s0` puro, esse isolamento lateral some. Com categorias, ele
permanece.

Ou seja: existe uma opção **estritamente melhor** que o `label=disable`, com a
mesma capacidade e uma propriedade de isolamento a mais — e ela custa digitar
uma palavra diferente. É o que este módulo usa.

### 3. `spc_t` lê o que `container_t` não lê — e isso dispensa o `:z`

Medido: um container `container_t` recebe *permission denied* ao ler
`site/package.json` (rótulo `user_home_t`); o mesmo container como `spc_t` lê.

A consequência é prática e boa: o `tofu` precisa do **repositório inteiro**
montado (os contextos de build são `../stack/services/…` e `../site`), e montar
com `:z` faria um `chcon -R` em `.git`, em `node_modules` e em tudo mais. Sob
`spc_t`, o `:z` é desnecessário.

## A decisão

**Duas vias, e a preferida é a que não faz concessão nenhuma.**

O `tools/scripts/lib/tofu.sh` resolve em um lugar só:

1. **Binário no host** (preferida). O `tofu` fala com o socket como o `docker`
   da linha de comando já fala — pelo grupo `docker` do usuário. Sem container,
   sem rótulo relaxado, sem discussão. O `iac-prereqs.sh` diz como instalar.
2. **Container oficial** (o que funciona sem instalar nada), com
   `--security-opt label=type:spc_t`, e mais dois alinhamentos que **não** têm
   nada a ver com SELinux e custaram tempo a achar:
   - `--group-add $(stat -c %g /var/run/docker.sock)` — o socket é `root:docker`
     e o `--user` tira o processo do grupo. Sem isto o erro é *permission
     denied* **depois** de o SELinux já ter passado, o que manda procurar no
     lugar errado. O gid é lido do socket, não fixado em 969.
   - `--user $(id -u):$(id -g)` — sem ele o `terraform.tfstate` e o
     `.terraform.lock.hcl` nascem do root no seu diretório, e você não os apaga
     sem sudo. É a armadilha 10 noutra roupa.
   - `-e HOME=/tmp` com um tmpfs — o provider chama o **buildx**, que quer
     escrever em `$HOME/.docker`. Com `--user` e sem `HOME`, o erro é
     `mkdir /.docker: permission denied`, que não menciona buildx.

E uma consequência que não é óbvia: na via 2 há **dois sistemas de arquivos**
na mesma configuração. O contexto de build é lido pelo processo do `tofu`
(caminho do container, `/repo/…`), enquanto o `host_path` de um bind mount é
resolvido pelo **daemon** (caminho do host). Daí a variável
`host_repo_root`, preenchida por `TF_VAR_host_repo_root`. Rodando no host os
dois caminhos coincidem — e é exatamente por isso que o erro só aparece na
outra via.

## O que isto NÃO torna seguro

Nada aqui muda o fato central: **quem fala com a API do Docker é root no host.**
O `spc_t` com MCS reduz o dano lateral; não reduz o dano. Este módulo é para
rodar no terminal de quem o escreveu, nunca num CI que constrói pull request —
que é precisamente a pergunta que o [ADR 0011](0011-como-o-agente-de-build-constroi-imagens.md)
respondeu com BuildKit rootless, e que continua valendo.

Se um dia este módulo precisar rodar em CI, a resposta não é endurecer o
container: é trocar o provider Docker por um provider que fale com uma API
remota autenticada.
