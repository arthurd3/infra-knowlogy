# 0014 — O mapa de mercado como dado verificável

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O módulo 4 nasceu de um cartaz: *"Stack SRE em 2026: o que 40 vagas pedem"*,
uma análise de mercado assinada por **Joel**, com sete exigências em barra
percentual e quatro quadrantes de ferramentas.

Um bom gancho — e, sozinho, material que este repositório não pode publicar. O
princípio inegociável daqui é que **toda afirmação técnica precisa ser
verificável por um comando**, e "82% das vagas pedem Terraform" não é
verificável aqui: é o levantamento de outra pessoa.

O risco maior, porém, não era esse. Era o que sempre acontece com roadmap:
alguém marca um item como "coberto", a lição nunca é escrita, e seis meses
depois o documento anuncia uma cobertura que não existe. Um checklist em
Markdown **envelhece mentindo**, e nada no repositório o contradiz.

## Decisão

O cartaz entra de três formas, e nenhuma delas é o arquivo original.

### 1. Vira dado versionado: `site/src/data/skills.json`

Cada exigência declara `demand` (o percentual, atribuído à fonte), `status`
(`coberto` | `parcial` | `ausente`), uma `gap` bilíngue dizendo **o que falta**,
e um bloco `evidence` com três listas: chaves de lição, nomes de checagem de
portão e arquivos de medição.

### 2. Ganha portão próprio: `site/tests/skills.test.ts`

É a parte que importa. O teste reprova quando:

- uma chave de lição citada **não existe** — nos dois idiomas;
- uma checagem citada **não aparece literalmente** em nenhum `tools/scripts/*.sh`;
- um arquivo de medição citado **não existe** em `site/src/data/`;
- um item `coberto` não tem lição, ou não tem checagem nem medição;
- um item `ausente` tem evidência (se tem, é pelo menos `parcial`);
- uma `gap` tem menos de 120 caracteres.

A última regra é editorial e foi copiada do `ports.test.ts`, pela mesma razão:
*"falta observabilidade"* é um rótulo, não uma informação. Quem lê precisa saber
**o que** falta para decidir se vale estudar.

A checagem de nome literal é **frágil de propósito**. Renomear uma checagem de
portão quebra o teste, e quem renomeou é obrigado a olhar o mapa. É melhor do
que o mapa apontar para uma checagem que deixou de existir sem ninguém notar.

### 3. É redesenhado, nunca republicado

O [ADR 0010](0010-imagens-de-terceiros.md) já prescrevia o caminho: sem licença
apurada, redesenha em SVG e credita com `redrawnFrom`. O
`MarketDemand.astro` é SVG escrito aqui, pinta por classe e segue o tema — e lê
os números do `skills.json`, para que não exista um segundo lugar onde eles
possam divergir.

O crédito nomeia o que de fato tem valor: **a análise**, não o arquivo.

## Onde ele mora

Na **home**, e não dentro de uma lição. É uma afirmação sobre o repositório
inteiro, e um roadmap escondido dentro de uma trilha é um roadmap que ninguém lê.

## Alternativas recusadas

**Publicar o PNG com crédito.** É um infográfico de terceiro com licença não
apurada. E há um custo técnico além do jurídico: o original é desenhado para
fundo escuro e ficaria ilegível no tema claro — o problema que o ADR 0010
descreve e para o qual a `plate` foi inventada. Redesenhar resolve os dois.

**Um `docs/SKILL-MAP.md` e nada mais.** Rápido, e envelhece calado — exatamente
o que este ADR existe para evitar.

**Deduzir o mapa da coleção de lições, sem arquivo.** Tentador: bastaria contar
lições por trilha. Mas ele perderia a única metade que importa — **o que não
existe**. Lacuna não tem arquivo para ser contado.

## Consequências

- O primeiro uso do mapa já decidiu trabalho: IaC era o único item acima de 80%
  com **nada** do lado de cá, e virou o módulo 4.
- Ele registra correções de fato sobre o mundo, não só sobre o repositório. Uma
  delas: o `ingress-nginx` foi **aposentado em março de 2026** (e o substituto
  planejado, o InGate, foi aposentado junto). O `docs/ROADMAP.md` mandava usá-lo
  no módulo 2 — instrução morta, corrigida para a Gateway API.
- O teste é um portão a mais que reprova conteúdo meu. Já reprovou: três das
  checagens que eu citei de memória **não existiam** nos scripts.
