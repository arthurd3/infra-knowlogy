# 0023 — O alerta que sai, e o receptor que prova que saiu

**Estado:** aceita · **Data:** 2026-09-21

## Contexto

O [ADR 0018](0018-slo-como-regra-que-roda.md) pôs as regras de SLO para rodar de
verdade: o `rules/slo.yml` tem 7 regras de gravação e 3 de alerta que o
Prometheus carrega e avalia, e o portão prova que elas avaliam.

A lição `burn-rate-alerting` parava num lugar honesto e insatisfatório: ela
mostrava o alerta chegar a `firing` no Prometheus e **admitia** que ali a
demonstração terminava. O Prometheus sabe que o alerta disparou; ninguém foi
avisado. Toda a parte que decide se alguém acorda — roteamento por severidade,
agrupamento, inibição, silenciamento — não existia.

Essa lacuna é diferente das outras do repositório. Não é uma decisão de escopo:
é a metade do problema que causa incidente ruim. Um alerta que dispara para a
pessoa errada, ou que dispara 40 vezes para o mesmo problema, produz o mesmo
resultado prático de um alerta que não dispara.

## Decisão

**Alertmanager no profile `obs`**, e um receptor que registra o que recebeu.

O Alertmanager sozinho não prova nada: ele tem uma API que lista alertas ativos
e um contador de notificações, e os dois podem estar certos com a entrega
falhando do outro lado. Por isso o profile ganhou **dois** serviços:

- `alertmanager` (quay.io/prometheus/alertmanager, pinado por digest), com
  roteamento por `severity`, `group_by: [alertname, severity]`, uma regra de
  inibição e dois receptores;
- `alert-sink`, que é a imagem do Caddy já usada pelo edge, servindo dois
  caminhos (`/plantao` e `/fila`) e **registrando cada POST no access log**.

O portão prova a cadeia inteira: o Prometheus conhece o Alertmanager
(`activeAlertmanagers`), um alerta com `severity=page` chega ao receptor
`plantao`, um com `severity=ticket` vai para `fila` e **não** acorda ninguém, o
contador de notificações sobe sem falhas, o access log do receptor registra o
POST, e um silêncio criado pela API deixa o alerta `suppressed` sem apagar a
regra.

## Consequências

**O que isto compra.** A lição deixa de terminar no `firing`. As quatro
propriedades que separam um alerta útil de um alarme — para quem vai, quantos
viram um, o que é suprimido por consequência de outro, e como calar sem apagar —
passam a ser demonstráveis com comando.

**O que custou.** Duas armadilhas medidas, e as duas viraram nota:

1. O `log` do Caddy fora do bloco do site configura o logger **do Caddy**, não o
   acesso ao site. O receptor registrava startup e nada mais, e parecia que a
   entrega não chegava.
2. Com `group_by` em `alertname` e `repeat_interval: 4h`, a segunda execução do
   portão **não gera notificação nenhuma** — o Alertmanager está certo, e a
   checagem é que estava medindo a coisa errada. A correção foi dar um nome
   único por execução ao alerta sintético (`PortaoEntregaPage$(date +%s)`).

**O que não foi feito.** Nenhum integrador real — nada de Slack, PagerDuty ou
e-mail. Um webhook para um Caddy local prova o mecanismo sem depender de conta,
credencial ou rede externa, que é a mesma régua do resto do repositório. O custo
é que a lição fala de escalonamento e rodízio de plantão como conceito, não como
configuração rodando.
