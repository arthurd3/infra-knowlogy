# 0020 — `citado`: o quarto estado do mapa de mercado

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O [ADR 0014](0014-o-mapa-de-mercado-como-dado.md) transformou o cartaz de
mercado em dado versionado com portão: `skills.json` mais `skills.test.ts`, e a
regra de que afirmação de cobertura sem evidência reprova.

Ele criou três estados: `coberto`, `parcial`, `ausente`. E eles bastaram
enquanto o que faltava era **trabalho**.

Ao planejar o caminho até a cobertura completa do cartaz, apareceu uma classe de
item que nenhum dos três descreve:

| item | por que não dá para medir aqui |
|---|---|
| EKS · GKE · AKS | exige conta em nuvem e cartão de crédito |
| Datadog, New Relic, Dynatrace | SaaS proprietário, exige licença |
| FinOps | exige uma fatura de verdade |

O princípio inegociável deste repositório é que **toda afirmação técnica precisa
ser verificável por um comando nesta máquina**. Para esses cinco, nenhum comando
é possível — não por falta de esforço, mas por natureza.

Deixá-los em `ausente` confunde duas coisas muito diferentes: *ninguém escreveu
nada* e *não dá para medir aqui*. É exatamente a distinção que o
[ADR 0009](0009-afirmacao-medida-e-afirmacao-citada.md) já tinha feito entre
afirmação medida e afirmação citada — só que aplicada ao mapa, e não à prosa da
lição.

## Decisão

Um quarto estado, **`citado`**:

> há lição que ensina o assunto, com `FieldNote` de fonte apurada, e **nenhuma
> checagem de portão é possível** — declarado.

O `skills.test.ts` o torna verificável com duas regras que fazem trabalhos
diferentes:

1. **`citado` exige lição bilíngue COM `FieldNote`.** Impede que o estado vire
   um jeito elegante de dizer "não fiz": para usá-lo, alguém precisou escrever a
   lição e apurar a fonte. Um item `citado` sem `FieldNote` seria prosa sem
   procedência, que é o que o ADR 0009 existe para impedir.

2. **`citado` PROÍBE checagem de portão.** É o que dá sentido ao estado. Se
   existe comando que prova, o item é `coberto` — e deixar os dois conviverem
   transformaria `citado` num refúgio para não escrever a checagem que daria
   trabalho.

Chip de quadrante não tem bloco `evidence` como as sete barras têm, então ele
ganha um campo `lesson`. Sem ele, `citado` num chip seria afirmação sem
endereço.

As duas regras foram conferidas injetando violação de propósito — um chip
`citado` sem `lesson` e uma demanda `citado` com checagem — e vendo as duas
reprovarem.

## O que isto muda na definição de "completo"

Antes: um mapa em que cinco itens ficariam para sempre em `ausente`, e
"100% coberto" seria inalcançável ou mentiroso.

Agora:

> **todo item está `coberto` (provado por comando) ou `citado` (ensinado com
> fonte, e declarado como não medível aqui).**

## Quando os cinco mudam de estado

**Não agora.** As lições que os ensinam ainda não existem, e o teste reprovaria
— corretamente. Eles continuam em `ausente` e convertem conforme a lição
chegar:

| item | lição que o converterá |
|---|---|
| EKS · GKE · AKS | a lição de cluster gerenciado, na trilha Kubernetes |
| FinOps | a lição de FinOps, na trilha de operação |
| Datadog, New Relic, Dynatrace | a lição sobre observabilidade gerenciada |

Isto é deliberado: o estado é um **mecanismo**, não uma anistia. Ele só vale
quando o trabalho de ensinar foi feito.

## Alternativas recusadas

**Deixar em `ausente` e explicar na `gap`.** É o que estava valendo, e o campo
`gap` de fato explicava. Recusada porque a lista de estados é o que o widget
colore e o que alguém lê em três segundos — e ali os cinco pareciam pendência,
não limite.

**Marcar como `coberto` quando a lição existir.** Seria mentira direta: não há
checagem, e o teste do ADR 0014 exige checagem ou medição para `coberto`.
Afrouxar essa regra para acomodar cinco itens destruiria o valor das outras
vinte e oito.

**Remover os cinco do cartaz.** O cartaz é a análise de outra pessoa e o mapa
existe para ser honesto sobre ela. Apagar o que não dá para cobrir é o oposto
do que o ADR 0014 quis fazer.
