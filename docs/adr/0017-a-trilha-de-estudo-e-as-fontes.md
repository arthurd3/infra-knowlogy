# 0017 — A trilha de estudo, e por que ela não é o `sources:`

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

Uma auditoria das 66 lições deu um retrato desconfortável:

| | |
|---|---|
| fontes citadas no total | 174 |
| dessas, **livros** | **0** |
| palestras | 4 |
| vídeos | 0 |

O campo `kind: book` existe no `content.config.ts` desde o começo e **nunca foi
usado**. E a trilha de Fundamentos — a porta de entrada — tinha **zero**
`<Term>`, um `Tradeoff` e um `FieldNote`, contra 13 `Term` e 9 `FieldNote` da
trilha de Segurança. Os primitivos didáticos foram inventados em ordem
cronológica (ADR 0009 trouxe `Tradeoff` e `FieldNote`; o `Term` nasceu com a
Segurança) e as trilhas escritas antes nunca voltaram para usá-los.

A pergunta que gerou este ADR: **onde entram livros e vídeos?**

## A distinção que decide tudo

O `sources:` de uma lição significa uma coisa específica: **o que foi usado para
escrevê-la**. É o que sustenta cada afirmação do texto, e é por isso que o
ADR 0009 o dividiu em documentação/especificação × relato de campo.

Um livro que ninguém leu para escrever aquela lição **não é fonte dela**.
Colocá-lo ali seria repetir exatamente o erro que o ADR 0009 corrigiu para
afirmação medida × afirmação citada — e corroeria a única coisa que dá valor à
bibliografia daqui, que é ela ser verdadeira.

## Decisão

Uma camada separada: `site/src/data/library.json`, indexada por **conceito** e
não por lição.

Por conceito porque conceito atravessa lição: `namespaces` aparece na 1 e
reaparece na 7, e quem quer estudar namespaces quer as duas de uma vez. São 10
conceitos e 26 referências distintas para a trilha de Fundamentos.

O componente `Deeper.astro` é injetado pela página da lição — nenhum MDX precisa
importá-lo — e resolve sozinho, pela `key`, quais conceitos tocam aquela lição.
Lição sem conceito mapeado não renderiza nada. Ele é estático, sem ilha e sem
JavaScript: bibliografia precisa ser legível numa aba que nunca pintou
(armadilha 20).

### As três regras editoriais, em `site/tests/library.test.ts`

1. **Toda referência diz por que ELA**, nos dois idiomas, com no mínimo 120
   caracteres — o mesmo piso do `how` em `ports.json` e da lacuna em
   `skills.json`. "Ótimo livro" não é informação; o leitor precisa saber o que
   *esta* referência entrega que as outras não.
2. **Todo conceito oferece ao menos um caminho gratuito.** Uma trilha de estudo
   feita só de livro pago exclui exatamente quem mais precisa dela.
3. **Todo conceito oferece ao menos uma indicação audiovisual.** Texto não é o
   único jeito de entrar num assunto, e para vários conceitos aqui a
   demonstração ao vivo ensina mais rápido que o capítulo.

Mais as invariantes estruturais: autor, veículo, ano, idioma, `accessed` e se é
gratuita; livro com ISBN ou link de editora; vídeo apontando para o YouTube; e
**toda lição de Fundamentos coberta por ao menos um conceito** — a regra que
impede a trilha de entrada de ficar justamente sem caminho para ir além.

## Verificação, que é o risco real aqui

Referência inventada — um ISBN alucinado, um link de YouTube que não existe —
envenena exatamente a credibilidade que este repositório construiu. Toda entrada
foi **conferida por busca antes de ser escrita**, e o campo `accessed` registra
a data. Duas consequências concretas:

- dois conceitos ficaram sem vídeo próprio porque não achei nenhum que eu
  pudesse confirmar. Em vez de inventar, reusei palestras verificadas que
  **de fato** cobrem o conceito, com a justificativa dizendo o que cada uma
  entrega ali;
- o item de capabilities foi resolvido com uma conversa longa em vídeo, e a
  justificativa diz que é conversa e não aula — porque é.

## Alternativas recusadas

**Tudo no `sources:`.** O schema já tem `kind: book`. Recusada pela distinção
acima: mistura "usei para escrever" com "vá estudar isto".

**Um `docs/LEITURAS.md`.** Some do site, onde está o leitor, e envelhece sem
nada contradizê-lo.

**Deduzir a bibliografia da coleção de lições.** Não há o que deduzir:
referência externa não está em lugar nenhum do repositório.

## Consequências

- `make site-test` foi de 83 para 95 casos; o `site-check.mjs`, de 10 para 11.
- A trilha de Fundamentos saiu de **0 para 15 `<Term>`**, em paridade PT/EN.
- Falta o mesmo tratamento para Kubernetes (que tem zero de todos os
  primitivos), CI/CD e as demais trilhas — declarado no roadmap, não escondido.
