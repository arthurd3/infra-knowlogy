# 0006 — Exceções de scanner com prazo de validade

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

Na primeira execução completa do `make verify`, o Trivy reprovou com 36
vulnerabilidades HIGH em três imagens. Investigando, elas se dividiam em três
grupos com naturezas bem diferentes:

| Grupo | Onde | Corrigível por nós? |
|---|---|---|
| dependências Go nossas (pgx, x/crypto, x/text) | `api-go` | **sim** — `go get -u` |
| `setuptools`/`msgpack` vendorizados pelo pip | `worker-py` | **sim** — remover o pip do runtime |
| stdlib do Go dentro do binário do Caddy | `web` | **não** — binário estático de terceiro |

Os dois primeiros foram consertados. O terceiro não tem conserto disponível: um
binário Go é estático, não há pacote para atualizar, e a tag `caddy:2-alpine`
mais recente já é a que estamos usando.

## Decisão

Registrar exceções em `tools/trivyignore.yaml`, **cada uma com motivo e
`expired_at`**, em vez de baixar o limiar de severidade ou desligar o scanner.

O prazo é o ponto central. Uma supressão sem data vira permanente por
esquecimento; com `expired_at`, o Trivy volta a reportar depois da data e o
build fica vermelho de novo, forçando a reavaliação.

## Consequências

- O portão continua reprovando qualquer CVE HIGH/CRITICAL **nova**. Só as 14
  listadas, nos caminhos listados, e só até 2026-11-30, passam.
- Cada exceção carrega a análise de exposição real — por exemplo, a CVE de
  `crypto/tls` é aceitável porque o TLS termina no `edge` e não neste container;
  a de `html/template` porque servimos arquivos estáticos e não renderizamos
  template.
- Em 2026-11-30 alguém precisa reavaliar. Se o Caddy tiver sido republicado com
  um Go mais novo, o arquivo inteiro some.

## Alternativas consideradas

- **Baixar o limiar para CRITICAL.** Recusada: cega o portão para toda HIGH
  futura, inclusive nas nossas próprias dependências — que era justamente onde
  estavam 13 dos 36 achados.
- **Compilar o Caddy nós mesmos com um Go atual.** Resolveria de fato, e
  acrescentaria uma toolchain inteira de build para manter, só para servir HTML
  estático. Recusada por desproporção, não por impossibilidade.
- **`--ignore-unfixed` e pronto.** Já usamos essa flag, e ela não ajuda aqui:
  estas CVEs *têm* correção a montante, ela só não chegou à imagem oficial.
