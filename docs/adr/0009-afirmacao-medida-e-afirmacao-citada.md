# 0009 — Afirmação medida e afirmação citada

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

O princípio inegociável deste repositório está na primeira linha do `CLAUDE.md`:

> Toda afirmação técnica das lições precisa ser verificável por um comando.

Ele funcionou. Foi o que pegou o erro da lição 3 — a explicação difundida de que
a shell form do `CMD` quebra o `docker stop` está incompleta, e só medindo se
descobriu que o BusyBox faz `exec` de um comando simples e que a causa verdadeira
é o tratamento especial de sinais no PID 1. Nenhuma revisão de texto teria pego
isso. O cronômetro pegou.

E ele tem um teto, que ficou evidente quando se olhou o que as 22 lições
**não** conseguiam dizer:

- **Como as empresas grandes operam.** Nada disso roda nesta máquina.
- **Tradeoffs com critério.** "Container ou VM?" depende de quem submete o
  código, e essa é uma pergunta sobre organizações, não sobre o kernel.
- **O que já deu errado com gente de verdade.** O `runc` vazou um descritor de
  arquivo e virou fuga de container (CVE-2024-21626); um Action do GitHub foi
  comprometido e exfiltrou segredo de 23 mil repositórios (CVE-2025-30066).
  Nenhum dos dois é reproduzível aqui, e os dois ensinam mais sobre a fronteira
  de segurança do que qualquer coisa que a stack demonstre sozinha.

A medida do problema: `grep -rn "](http" site/src/content/lessons/` devolvia **um
único link** no corpo das 22 lições — e ele estava quebrado.

A tentação óbvia é escrever esse conhecimento na prosa mesmo. É exatamente assim
que um número de blog vira lenda: ele aparece ao lado de um número medido, com a
mesma tipografia e a mesma cara de fato, e ninguém mais distingue os dois.

## Decisão

Existem **duas classes de afirmação**, com padrões de prova diferentes, e a
diferença é visível na página.

| | Afirmação medida | Afirmação citada |
|---|---|---|
| Prova | um comando do portão | uma fonte, com data |
| Onde nasce | `make verify`, `k8s-verify`, `sizes.sh` | postmortem, thread, blog de engenharia, palestra |
| Como aparece | prosa, tabela, `<Callout>`, `<RunIt>`, `<Figure>` | **`<FieldNote>`**, e só ele |
| Borda | contínua | **tracejada** |
| Rodapé | — | "não medido aqui — relatado por ‹fonte›, ‹quando›" |

O `<FieldNote>` exige `source` e `url`; sem elas o componente não é um relato de
campo, é uma opinião, e `site/tests/content.test.ts` reprova. A URL também tem
que estar no `sources:` do frontmatter — a seção "Fontes" é o que o leitor
revisita depois, e um relato que só existe no meio do texto desaparece.

O campo `sources` ganhou `kind` (`spec`, `docs`, `blog`, `thread`, `postmortem`,
`talk`, `book`) e `accessed`. A página agrupa em **"Documentação e
especificação"** e **"Relatos de campo"**: um diz como a coisa DEVE se comportar,
o outro diz o que aconteceu com alguém. A data existe porque relato envelhece —
uma thread de 2019 sobre custo de control plane fala de preços que já mudaram
duas vezes.

### O tradeoff é a terceira peça

Saber os dois lados não basta; o leitor precisa do **critério**. O
`<Tradeoff>` exige `whenA` e `whenB` — sem eles não é tradeoff, é tabela
comparativa, e tabela comparativa devolve a decisão para quem não tem repertório
de tomá-la. O componente também marca o que ESTE repositório escolheu e linka o
ADR correspondente: a intenção é que o leitor possa discordar com informação, não
que ele obedeça.

### E o leitor precisa poder errar

`<Quiz>` e `<LabExercise>` existem porque ler não é o mesmo que aprender, e o
portão mede se a LIÇÃO está certa, nunca se o leitor entendeu. A regra que define
o quiz: **toda alternativa explica por que está certa ou errada**, inclusive as
erradas. Um widget que só pinta de verde a resposta certa ensina a reconhecer o
gabarito, não o assunto. `site/tests/quiz.test.ts` reprova alternativa sem
explicação.

## Alternativas recusadas

**Continuar só com o que se mede.** Honesto e pobre. A lição sobre isolamento
ficaria sem o caso que prova que o kernel é mesmo a fronteira; a lição sobre
orquestração ficaria sem o contraditório de quem roda escala grande sem
Kubernetes. O repositório estaria certo sobre tudo o que diz e calado sobre
metade do que importa.

**Citar solto dentro da prosa.** Rápido, e é a raiz do problema: a citação fica
indistinguível da medição. Daqui a dois anos ninguém sabe quais números foram
cronometrados nesta máquina e quais vieram de um post de 2021.

**Uma seção "Leitura adicional" no fim.** Melhor que nada e desconectada: o
relato só ensina quando está encostado na afirmação que ele sustenta. No fim da
página ele vira bibliografia decorativa.

## Consequências

**A favor:**

- O repositório passa a poder ensinar tradeoff, escala e incidente real sem
  abrir mão do que o torna confiável.
- A fronteira é visual e testada, não uma promessa no `CLAUDE.md`.
- O `kind` das fontes deixa o índice do Qdrant mais útil: dá para perguntar por
  relato de campo sem trombar com documentação.

**Contra, e assumido:**

- **Mais cerimônia para escrever.** Uma frase citada agora custa um componente,
  uma URL e uma entrada no frontmatter. É o preço de a citação não se disfarçar.
- **Fonte externa morre.** Link quebra; `accessed` dá ao leitor a data para
  procurar no Internet Archive, e nada mais. Não há verificação automática de
  link vivo — seria uma checagem que depende de rede, e os portões deste
  repositório rodam offline de propósito.
- **Julgamento fica com quem escreve.** Nada impede alguém de pôr num `<Callout>`
  o que deveria estar num `<FieldNote>`. A revisão humana continua sendo a
  última linha.
