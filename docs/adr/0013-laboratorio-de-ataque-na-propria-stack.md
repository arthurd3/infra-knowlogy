# 0013 — Ensinar segurança atacando a própria stack

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

A trilha de Segurança nasceu de um cartaz — "as portas mais atacadas", oito
linhas com número, serviço, uso e "ataques comuns". Um bom gancho, e um material
que não se sustenta sozinho neste repositório: o princípio inegociável daqui é
que **toda afirmação técnica precisa ser verificável por um comando**.

"A porta 445 é perigosa" não é verificável. "O `edge` desta stack não alcança o
`db` na porta 5432" é — basta tentar. A pergunta deste ADR é como transformar
uma trilha inteira de segurança no segundo tipo de afirmação, sem introduzir no
repositório coisas que ele passaria a ter que defender.

Há uma dificuldade específica em ensinar defesa: **uma defesa que ninguém tentou
atravessar é uma suposição**. O `verify.sh` pergunta "a configuração está lá?";
isso é inspeção, e inspeção não distingue uma regra que funciona de uma regra
que está escrita errado. Para afirmar que a segmentação vale, é preciso tentar
atravessá-la e falhar.

E há uma segunda dificuldade, maior: a lição central da trilha — injeção de SQL —
só ensina se o ataque **funcionar** pelo menos uma vez. Comparar "0 linhas" com
"0 linhas" não ensina nada.

## As opções

### (a) Um endpoint vulnerável de propósito na API — recusada

O caminho óbvio: acrescentar ao `api-go` uma rota que concatena a entrada do
usuário na consulta, e apontar a lição para ela.

Três problemas, e o terceiro é decisivo:

1. **O código fica no repositório.** Quem clonar isto e subir a stack passa a
   ter um caminho de injeção real. "É só de estudo" não é uma propriedade que
   sobrevive a um `git clone`.
2. **O portão teria que aprender a ignorá-lo.** O `verify` passaria a conviver
   com uma vulnerabilidade conhecida, e a distinção entre "scanner quebrou",
   "achou CVE" e "achou o nosso bug de mentira" viraria mais uma exceção com
   prazo (ADR 0006) — dessa vez sem prazo.
3. **Corrói a premissa.** Este repositório afirma que a stack dele é endurecida
   e verificada. Embutir uma vulnerabilidade para fins didáticos torna essa
   afirmação falsa, e a próxima pessoa não tem como saber quais outras
   vulnerabilidades são "de propósito".

### (b) Subir um alvo vulnerável pronto (DVWA, juice-shop) — recusada

Resolve o problema 1, porque o código vulnerável é de outro projeto. Cria outro:
vira uma **segunda aplicação** no repositório, contra a Regra 1 do ROADMAP —
módulo novo é vista de deploy nova, nunca app nova. E a comparação lado a lado
deixa de ser honesta: as lições passariam a falar de um sistema que não é o que
o resto do repositório mede.

### (c) Apontar para um alvo externo de treino — recusada

Não é medível aqui, não roda offline, e envelhece na primeira vez que o serviço
mudar. Pior: ensina, por exemplo, a apontar ferramenta para um host que não é
seu. Mesmo com um alvo que autoriza isso explicitamente, é um hábito que este
repositório não quer normalizar.

### (d) Só teoria, sem laboratório — recusada

É o que quase todo material de segurança faz, e é exatamente o que o princípio
deste repositório rejeita. Uma trilha de seis lições sem um comando que rode
seria a primeira do site a pedir confiança em vez de oferecer prova.

## Decisão

**Atacar a stack endurecida deste repositório, de dentro, com as defesas
ligadas — e provar cada ataque falhando.**

`tools/scripts/attack-lab.sh`, exposto como `make attack-lab`. Portão
independente, no precedente do ADR 0007: quem estuda só Docker não precisa
rodá-lo, e o estado bom conhecido do `verify` (32 passaram) não muda.

A semântica é **invertida** em relação aos outros portões: uma checagem passa
quando o ataque **falha**. São onze ataques — varredura de portas, acesso direto
ao banco, travessia entre redes, senha errada, injeção pela API, SSRF, leitura
do segredo, webshell, shell na imagem distroless e exfiltração.

### O único ataque que funciona, e onde ele mora

O passo 6 é a demonstração de injeção de SQL, e ele **precisa vazar**. A solução
para vazar sem deixar nada para trás:

- roda num `psql` descartável, na imagem `postgres:17-alpine` que a stack já
  pina por digest;
- cria uma tabela **temporária** dentro de um `BEGIN … ROLLBACK`;
- executa a MESMA entrada hostil de duas formas — concatenada no texto da
  consulta e passada como parâmetro — e imprime as duas contagens.

Medido: **3 linhas** concatenada, **0** parametrizada. Nenhuma linha de código
vulnerável entra na aplicação, e a tabela nem chega a existir depois do
`ROLLBACK`.

O script marca esse passo como `teaching` em vez de `blocked`, e o resumo o
exclui da contagem de ataques repelidos. Um portão que contasse a demonstração
como falha estaria medindo a coisa errada.

### A trava de alvo

O script confere, antes do primeiro pacote, que o alvo é `127.0.0.1` e que os
containers são os do projeto `infra-knowlogy`. Qualquer outra coisa aborta. Não
há variável de ambiente que mude o alvo — um script que dispara ataques não
deveria aceitar um endereço vindo de fora.

## Consequências

**O que ganhamos.** Toda afirmação de defesa da trilha tem um passo que a prova,
e as lições citam `site/src/data/attack-lab.json` em vez de números escritos à
mão. Quebrar uma defesa passa a ser barulhento: o exercício da lição 6 desliga o
`read_only` de propósito e o laboratório acusa.

**O que custa.** Mais um portão para manter, e uma sobreposição deliberada com o
`verify.sh` — os dois checam segmentação, segredo e rootfs. A sobreposição é o
ponto: o `verify` pergunta se a configuração está escrita, o `attack-lab`
pergunta se ela segura. Se um dia as duas discordarem, a discordância é o achado.

**O que ficou de fora.** O laboratório não testa o perímetro de fora do host,
porque a trava o impede — e porque o que está fora do host não é desta stack.
Também não há ataque de negação de serviço: medir amplificação de DNS exigiria
um resolvedor aberto, que é justamente o que nenhum host deveria ter. Esses
números vivem em `FieldNote`, citados e marcados como não medidos aqui
(ADR 0009).

**Descoberta não planejada.** Na primeira execução, o passo 2 reprovou dizendo
que a porta 5432 estava publicada — e não era desta stack: era um Postgres de
outro projeto, esquecido rodando na máquina de desenvolvimento. O script passou
a **atribuir** o socket antes de acusar, e a nomear o intruso só no terminal de
quem roda, nunca no JSON versionado. O laboratório encontrou um banco esquecido
antes de encontrar qualquer coisa na stack que ele foi escrito para atacar.
