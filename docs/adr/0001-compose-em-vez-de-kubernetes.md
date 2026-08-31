# 0001 — Compose em vez de Kubernetes

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

A stack de referência precisa ser, ao mesmo tempo, código de produção legítimo e
material didático legível. Kubernetes é o padrão de fato em orquestração, então a
escolha por Compose precisa ser justificada em vez de assumida.

## Decisão

Usar Docker Compose com sobreposição de arquivos (`base` + `dev`/`prod`/`obs`).

Três razões:

1. **A relação sinal/ruído.** Um Deployment + Service + ConfigMap + Secret +
   Ingress + NetworkPolicy em Kubernetes descreve o que um `compose.yaml` de 200
   linhas descreve. Para ensinar *Docker*, o YAML do Kubernetes acrescenta
   conceitos (pod, controller, serviço virtual) que não são o assunto.
2. **É o que a maioria dos projetos realmente precisa.** Um host bem configurado
   com Compose atende à esmagadora maioria das cargas de trabalho reais.
3. **O caminho de saída é curto.** Toda decisão aqui — healthcheck na imagem,
   config por ambiente, segredos por arquivo, liveness separada de readiness —
   traduz direto para Kubernetes. Nenhuma delas precisa ser desfeita.

## Consequências

Aceitamos, e documentamos explicitamente na lição 8, que o Compose **não** faz:

- reiniciar container `unhealthy` (ele só marca o estado);
- deploy sem downtime (não há rolling update);
- escalar entre máquinas;
- reagendar em caso de falha do nó.

Um módulo futuro sobre orquestração deve **portar esta mesma stack** para
Kubernetes, e não introduzir uma stack nova — a comparação lado a lado é boa
justamente porque a aplicação é a mesma.

## Alternativas consideradas

- **Kubernetes (k3s/kind) desde o começo.** Recusada: acrescenta uma camada
  conceitual grande antes de os fundamentos de Docker estarem firmes.
- **Docker Swarm.** Recusada: resolveria rolling update e healthcheck com
  reinício, mas é um beco sem saída em termos de ecossistema e emprego.
