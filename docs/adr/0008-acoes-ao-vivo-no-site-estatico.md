# 0008 — Ações ao vivo num site que continua estático

**Estado:** aceita · **Data:** 2026-09-19

## Contexto

O site de lições é, desde o começo, **100% estático**. A decisão estava escrita
só num comentário do `site/astro.config.mjs`:

> O site é 100% ESTÁTICO. Nenhum widget precisa de servidor: os simuladores
> rodam inteiramente no navegador, com dados medidos gravados em build time.

Isso vale muito: o container que serve o site é um servidor de arquivos sem
runtime nenhum (27 MB, zero Node), e a mesma pasta `dist/` pode ser publicada em
qualquer lugar.

Só que o repositório tem um princípio mais forte que esse — **toda afirmação
técnica precisa ser verificável por um comando** — e havia uma assimetria
incômoda: o leitor era convidado a confiar em afirmações ("o SSRF é recusado",
"o redirect responde 302") cuja verificação exigia sair do site, abrir um
terminal e rodar `make verify`. Quem estava lendo no ônibus não verificava nada.

A pergunta deste ADR: dá para o leitor **rodar a verificação a partir da página**
sem que o site deixe de ser estático?

## Decisão

Sim, e sem tocar em infraestrutura nenhuma — porque o edge já resolve isso.

### 1. O mesmo-origem já existia; foi só usá-lo

O `stack/services/edge/Caddyfile` roteia, no mesmo host e na mesma porta:

| caminho | destino |
|---|---|
| `/edge-health` | `respond 204` (o próprio Caddy) |
| `/api/*` | `reverse_proxy api:8080` |
| `/r/*` | `reverse_proxy api:8080` (sem o prefixo) |
| qualquer outro | `reverse_proxy web:8080` (o site) |

Com `make up`, o site e a api saem de `http://127.0.0.1:8080`. Um `fetch('/api/links')`
disparado pela página é **mesmo-origem**: sem CORS, sem servidor novo, sem uma
linha de configuração a mais. O site continua sendo arquivos estáticos; quem
responde `/api/*` é o proxy que já estava lá.

**Alternativa recusada:** adicionar CORS na api para o site poder chamá-la de
outra origem (ex.: `localhost:4321`). Recusada porque é superfície de ataque
criada para conveniência de desenvolvimento, e porque o cenário que ela
habilitaria — site numa origem, api em outra — não é o cenário que as lições
descrevem.

### 2. Degradar para uma gravação, nunca para uma simulação

Fora do edge (`make site-dev` na 4321, ou o site publicado em qualquer lugar),
`/api/*` não existe. Os widgets detectam isso com um probe real e caem em **modo
demonstração**, sempre rotulado, com a data da gravação à vista.

O que se reproduz ali **não é uma simulação**: é a resposta de verdade que a
stack deu, gravada em `site/src/data/recorded-gate.json` por
`tools/scripts/record-gate.sh`. E o código que roda é o **mesmo** nos dois modos
— o que muda é só o transporte:

```
runGate(base, { fetch: <navegador | gravado>, ... })
```

**Alternativa recusada:** escrever um "modo demo" separado, com respostas
plausíveis escritas à mão. Recusada porque envelhece calado — ninguém reexecuta
uma simulação, e ela passa a ensinar a versão antiga do sistema como se fosse a
atual. Com o transporte gravado, `site/tests/recorded.test.ts` roda o portão
inteiro sobre o arquivo e reprova se ele divergir do que o portão checa hoje.

### 3. O probe é específico, não otimista

`probe()` só diz "stack no ar" quando **`/edge-health` responde 204 exato** e
`/api/links?limit=1` devolve JSON com um campo `count`.

Os dois detalhes têm motivo, e os dois vieram de falhas reais:

- **204 exato, não `res.ok`.** Um servidor de arquivos estático responde a
  página de 404 com **status 200** (`try_files … /404.html`). Aceitar qualquer
  2xx fazia o widget anunciar "o proxy está de pé" em cima de um site sem proxy
  nenhum. Um teste pegou isso (`gate.test.ts`).
- **JSON com `count`, não `res.ok`.** Mesmo motivo, do outro lado: `/api/links`
  num site estático devolve HTML de 404 com 200.

### 4. `/readyz` não é exposto pelo edge, e continua assim

A rota de readiness da api **não** está no Caddyfile — só `/api/*` e `/r/*` são
publicados. Seria conveniente usá-la no probe; não é correto. Endpoint de saúde
não é superfície pública: ele descreve dependências internas e serve de
instrumento de reconhecimento.

O widget usa `/api/links?limit=1`, que o edge já publica e que, de quebra,
exercita o caminho api → Postgres — que é o que realmente importa saber antes de
oferecer um botão que escreve no banco. O motivo está explicado no próprio
widget, porque a ausência é a lição.

### 5. A lógica não sabe o que é React nem o que é português

`site/src/lib/gate.ts` e `site/src/lib/lab.ts` não importam React, não têm
string de interface e não chamam o `fetch` global: tudo entra por parâmetro. As
ilhas traduzem `messageKey` e desenham; os testes injetam um `fetch` falso e
rodam em milissegundos, sem Docker e sem navegador.

Isso não é purismo. Foi o que permitiu escrever os casos que interessam — a api
devolvendo HTML com 200, o redirect sumindo, o SSRF **não** sendo bloqueado —
sem precisar provocar cada um deles numa stack de verdade.

## Consequências

**A favor:**

- O leitor verifica de dentro da página: 7 checagens, as mesmas de
  `tools/scripts/lib/smoke.sh`, com a resposta crua à vista.
- O site continua estático. `output: "static"`, container sem runtime, `dist/`
  publicável em qualquer lugar. Nada disso mudou.
- A gravação é testada contra o portão, então não pode ficar para trás calada.

**Contra, e assumido:**

- **Mais código no cliente.** As ilhas novas somam alguns kilobytes de JS —
  carregados só quando o widget entra na tela (`client:visible`), e nunca no
  texto da lição.
- **Dois caminhos para o leitor.** Quem abre o site publicado vê a gravação e
  quem roda `make up` vê o ao vivo. O rótulo e a data existem justamente para
  que ninguém confunda os dois.
- **O navegador esconde o 302.** Com `redirect: "manual"`, o `fetch` devolve uma
  resposta opaca (`type: "opaqueredirect"`, `status: 0`): dá para provar que
  **houve** um 3xx, não para ler o número. O `curl` do portão lê; o widget diz
  "3xx confirmado". A diferença está anotada no código.
- **O widget escreve no banco.** Cada execução cria dois links no Postgres, como
  o `make verify` já criava. É a stack de estudo do próprio leitor.

## Como regravar

```bash
make up                                  # a stack precisa estar de pé
bash tools/scripts/record-gate.sh        # regrava recorded-gate.json
cd site && npm test                      # prova que a gravação ainda casa
```
