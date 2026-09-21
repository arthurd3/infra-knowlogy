# 0022 — Operação como trilha transversal, e medida na stack que já existe

**Estado:** aceita · **Data:** 2026-09-21

## Contexto

O quadrante **Resiliência & operação** do cartaz de mercado estava em **0 de 7**
— o único inteiramente vazio. Ele reúne coisas que não se parecem umas com as
outras: troubleshooting de Linux, redes, tuning de banco, postmortem, plantão,
FinOps e IAM.

A tentação era criar o Módulo 5: um diretório novo, um `make ops-verify`, uma
stack de demonstração. O [ADR 0001](0001-compose-em-vez-de-kubernetes.md) e o
`docs/ROADMAP.md` dizem que módulo novo **porta a mesma aplicação para uma vista
de deploy nova** — e operação não é uma vista de deploy. É o que se faz com a
vista que já existe.

## Decisão

**Trilha transversal**, no modelo da trilha de Segurança: sem diretório de
módulo, sem portão próprio. As checagens entram como **passo 10 do
`verify.sh`**, onde a stack do módulo 1 já está de pé, e as medições saem do
`tools/scripts/ops-measure.py` para `site/src/data/ops-measured.json`.

Sete lições bilíngues na trilha `operacao`: cinco medidas aqui e duas
**`citado`** (ADR 0020), porque cultura de incidente, plantão, fatura e política
de acesso não se medem numa máquina.

## Alternativas recusadas

**Módulo 5 com stack própria.** Uma stack de demonstração para "mostrar o OOM
killer" teria a doença que este repositório evita desde o ADR 0001: exemplo
construído para a lição, em vez de lição construída sobre o que roda. O OOM
medido aqui é o de um container com `--memory=64m` de verdade; o Postgres
medido é o que o `make up` sobe.

**Portão `make ops-verify` separado.** Os portões são independentes de propósito
([ADR 0007](0007-kind-e-o-porte-para-kubernetes.md)) para que quem estuda Docker
não instale kind. Aqui o argumento se inverte: **as checagens de operação
precisam exatamente da stack que o `verify` já subiu**, e um portão separado
gastaria minutos subindo-a de novo para medir a mesma coisa.

**Instalar `strace`, `perf`, `bpftrace` e `conntrack` no host.** Recusada por
duas razões. A primeira é que o repositório não deveria pedir mudança na máquina
de quem estuda — o padrão do `kubeconform`, do `helm` e do `tofu` conteinerizados
já existe. A segunda é que rodar `strace` num container **é a lição**: obriga a
enfrentar capability e seccomp, e foi assim que a correção do conselho apareceu.

**Deixar RCA, plantão, FinOps e IAM em `ausente`.** Seria honesto e inútil. O
estado `citado` foi criado no ADR 0020 exatamente para isto: há lição, há fonte
apurada, e **nenhuma checagem é possível** — declarado, não disfarçado.

## Consequências

**Quatro medições contrariaram o que eu ia escrever, e todas viraram lição.**

1. **O UID não é traduzido.** O Postgres roda como UID 70 e aparece no `ps` do
   host como `avahi`, porque o UID 70 deste Fedora é o daemon de mDNS. Não é
   tradução errada: o namespace de usuário vem **desligado** por padrão, e o
   número atravessa intacto. A checagem do portão compara o UID visto de dentro
   com o visto de fora e falha se eles divergirem — porque divergir significaria
   que alguém ligou o `userns-remap`, e aí a lição muda.

2. **`strace` não precisa de `SYS_PTRACE`.** O conselho difundido está
   incompleto: a capability governa tracear processo de **outro** usuário; o que
   exigia a flag era o perfil seccomp antigo do Docker, e isso mudou.

3. **Um rótulo custa 8 segundos.** Um nome inexistente de dois rótulos falha em
   1,0 ms; um nome de serviço de um rótulo falha em **7826 ms**. A diferença é
   de **8000×** e explica a classe de incidente registrada como "a rede está
   lenta" — a espera acontece dentro de `gethostbyname()`, antes de existir
   socket, então nenhuma métrica de rede se move.

4. **Duas otimizações que eu ia anunciar como vitória não eram.** O
   `effective_cache_size` estava em 4 GB contra um cgroup de 512 MiB — oito vezes
   — e corrigi-lo **não mudou plano nenhum** nesta escala de tabela. E o
   `work_mem` que evita o derrame em disco comprou **17%**, não uma ordem de
   grandeza; o custo real são 35 MB de arquivos temporários que a duração da
   consulta esconde. As duas correções ficaram, com o motivo escrito: o valor
   antigo era **falso**, não caro.

**Uma mudança de stack, e ela tem preço.** O `db` ganhou
`shared_preload_libraries=pg_stat_statements` no `command:`, que exige recriar o
container e custa ~1% de CPU. É a única forma de responder "qual consulta está
lenta" em vez de "o banco está lento", e a extensão **normaliza os literais** —
mil execuções com mil valores viram uma linha com `calls = 1000`.

**O que continua fora do alcance desta máquina**, declarado: `perf` e eBPF
(rodariam conteinerizados, mas ainda não rodam), replicação e failover do
Postgres (exigem mais de uma instância), e as quatro práticas `citado`.
