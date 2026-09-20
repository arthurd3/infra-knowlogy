# 0018 — SLO como regra que roda, e não como capítulo

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O profile `obs` existia desde o módulo 1 e nunca tinha sido ensinado: Prometheus,
Grafana, Loki, Alloy e quatro exporters de pé, endurecidos, e **zero lições**.
Era a maior desproporção do repositório — 80% das vagas pedem observabilidade, e
o mapa de mercado (ADR 0014) marcava a lacuna com nome e percentual.

Escrever a trilha esbarrou numa decisão de fundo: **como ensinar SLO sem
mentir.** A maioria do material da área explica a matemática do orçamento de
erro em prosa e para por aí. O princípio inegociável daqui não permite isso —
"14,4× consome 2% do orçamento em uma hora" é afirmação verificável, e
verificável significa que alguém rodou.

## Decisão

O SLO deixou de ser assunto de lição e virou **configuração que o Prometheus
carrega**: `stack/services/observability/rules/slo.yml`, com 7 regras de
gravação e 3 de alerta, montado no container e referenciado por `rule_files:`.

E o portão passou a provar as afirmações das lições, não a existência do
arquivo. Cinco checagens novas no passo 9 do `verify.sh`:

| checagem | o que ela impede |
|---|---|
| regras de SLO carregadas | erro de sintaxe no YAML faz o Prometheus subir e **não avaliar nada** — painel bonito, alerta que nunca dispara |
| toda regra avalia sem erro | regra com `health: err` aparece como carregada e não produz série |
| o SLI tem valor | renomear uma rota na api quebraria o `route!~` em silêncio: query válida, resultado vazio, alerta inexistente |
| o relabel do cAdvisor descarta N amostras | apagar o filtro transforma a lição 4 em mentira **e** a stack em GB de RAM |
| medições gravadas | os números das lições saem de `obs-measured.json`, regravado a cada execução |

## O que a medição descobriu, e que mudou a lição

### O denominador tem um piso constante de 16 requisições por minuto

Com a stack parada e só o monitoramento rodando, a api atende:

```
/healthz    1714
/readyz     1708
/metrics    1142
tráfego de usuário de verdade     132
```

**Vinte e quatro requisições de infraestrutura para cada uma de usuário** nesta
medição — e essa razão oscila com a carga, o que a torna ruim como afirmação.

O número que **não** oscila é o piso, e ele é derivável: healthcheck a cada 10 s
em duas rotas dá 12 por minuto, e o scrape a cada 15 s dá mais 4. **Dezesseis
requisições por minuto, com zero usuários, para sempre** — medido e conferido
contra a aritmética dos intervalos.

Qualquer serviço abaixo desse volume tem o denominador do SLI dominado pelo
próprio monitoramento. Um
SLI sobre "todas as requisições" mostraria uma queda **total** do serviço como
96% de sucesso, e o alerta nunca dispararia.

Por isso o `slo.yml` começa com uma exclusão de rota, e não com uma métrica.
Não é detalhe de implementação: é a diferença entre medir o usuário e medir a si
mesmo. Nenhum material que consultamos cita esse número, porque ele só aparece
quando alguém mede a própria stack.

### O alerta dispara, e não some no conserto

O Postgres foi parado de propósito, com tráfego de usuário continuando:

```
t     ratio5m   ratio1h   14,4x limiar   alertas
  0s   1.0000    1.0000   0.0720        QueimandoRapido=firing,
                                        QueimandoMedio=pending,
                                        RitmoDeTicket=pending
```

Com o banco de volta e a api respondendo 201, o alerta **continuou disparando** —
a janela de 5 minutos ainda continha os erros. É o comportamento correto e é uma
informação que ninguém tem antes do primeiro incidente.

### O cAdvisor descarta 96%

`scrape_samples_scraped` menos `scrape_samples_post_metric_relabeling`: 1.227
amostras publicadas, 47 guardadas. E o `node-exporter`, que ninguém culpa, é o
maior contribuinte da stack — maior que o cAdvisor mesmo sem filtro.

### O rótulo `level` tinha seis grafias

Medido escrevendo a lição 5: `ERROR INFO error info warn warning`. A api em Go, o
worker em Python e o Caddy escrevem o nível cada um do seu jeito, e
`{level="error"}` **não casa** `ERROR` — quem consulta num incidente recebe
metade dos erros sem aviso.

Corrigido com um `stage.template` no `config.alloy`. E a correção **pareceu não
funcionar**: o endpoint de valores de rótulo responde pela granularidade do
índice (24h), não pela janela pedida. Quem prova é consultar as linhas.

## Alternativas recusadas

**Ensinar SLO só em prosa, com exemplos de documentação.** É o que quase todo
material faz, e teria sido muito mais rápido. Recusada porque o repositório
inteiro existe para o contrário: a receita do SRE Workbook está implementada e
disparando, ou não está ensinada.

**Incluir o Alertmanager.** Seria o fecho natural — roteamento, agrupamento,
silenciamento, escalonamento. Recusada **nesta versão** por escopo, e declarada
em voz alta na lição 7 e no roadmap. Uma trilha que ensinasse SLO fingindo que
`firing` é o fim da história estaria ensinando a metade fácil.

**Acrescentar tracing com OpenTelemetry.** Exigiria propagar contexto pelas três
aplicações — api, Redis, worker. É trabalho de módulo, não de trilha, e a lição
1 diz isso com todas as letras em vez de desenhar "três pilares" sugerindo
completude.

## Consequências

- `make verify` foi de 32 para **37 checagens**; o passo 9 saiu de 4 para 9.
- `tools/scripts/obs-measure.py` grava `site/src/data/obs-measured.json`, e os
  diagramas leem dele — número de diagrama que envelhece é número que mente.
- A trilha `observabilidade` tem 7 lições bilíngues, 7 diagramas e 7 quizzes.
- O mapa de mercado (ADR 0014) move observabilidade de `parcial` para `coberto`,
  com as seis checagens de portão como evidência.
- `prometheus.yml` e `compose.obs.yaml` mudaram: `rule_files:` e o bind mount do
  diretório de regras.
