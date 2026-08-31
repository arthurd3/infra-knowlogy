# 0003 — Como lidar com o socket do Docker na observabilidade

**Estado:** aceita · **Data:** 2026-08-31

## Contexto

Coletar métricas e logs **por container** exige, por definição, perguntar ao
Docker quais containers existem. Isso colide de frente com a Regra #1 do OWASP:
nunca monte `/var/run/docker.sock` num container.

A tensão é real e não tem solução perfeita. A pior resposta seria esconder o
problema — montar o socket sem comentário, como faz a maioria dos tutoriais de
"stack de monitoramento com Docker Compose".

## Decisão

Três medidas, em ordem de importância:

1. **A stack padrão não toca o socket.** Toda a observabilidade fica atrás do
   profile `obs`. `make up` sobe seis containers e nenhum deles enxerga o Docker.
2. **O Alloy fala com um proxy, não com o socket.** O `docker-socket-proxy` monta
   o socket e expõe uma allowlist mínima: apenas leitura de `/containers`.
   `POST`, `EXEC`, `IMAGES`, `VOLUMES`, `BUILD` e todo o resto são negados — em
   particular `POST /containers/create`, que é o endpoint que transformaria o
   acesso em root no host.
3. **O cAdvisor recebe o socket, e isso é documentado.** Ele lê cgroups direto de
   `/sys` e precisa de mais do que a API HTTP oferece, então o proxy não resolve
   o caso dele. Montamos `:ro` com `no-new-privileges`.

## Descoberto ao implementar (2026-08-31)

Duas coisas que só apareceram rodando de verdade, e que valem mais que o plano:

1. **O SELinux bloqueia o socket, e o sintoma engana.** Em Fedora/RHEL,
   `/var/run/docker.sock` tem rótulo `container_var_run_t` e o tipo
   `container_t` do container não o alcança. O `docker-socket-proxy` **sobe**,
   o HAProxy fica de pé, e toda requisição volta `503 No server is available`.
   Nada na mensagem menciona SELinux. Prova em dois comandos:

   ```bash
   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro alpine/curl \
     curl -s --unix-socket /var/run/docker.sock http://localhost/_ping     # nada
   docker run --rm --security-opt label=disable \
     -v /var/run/docker.sock:/var/run/docker.sock:ro alpine/curl \
     curl -s --unix-socket /var/run/docker.sock http://localhost/_ping     # OK
   ```

   Aplicamos `label=disable` **apenas** no socket-proxy. A alternativa, `:z` no
   socket, reetiquetaria o socket do HOST e afetaria o daemon inteiro.

2. **A allowlist mínima era mínima demais.** O Alloy também consulta `/networks`
   para rotular alvos com a rede de cada container; com `NETWORKS: 0` ele levava
   `403` e não descobria nada. Liberamos a leitura de redes e mantivemos
   `POST: 0`, que é o que realmente impede a escalada.

## Consequências

- **`:ro` limita, mas não elimina o risco.** A API do Docker é HTTP sobre o
  socket: o modo somente-leitura impede escrever *no arquivo de socket*, não
  impede enviar requisições. Dizemos isso explicitamente no comentário do
  `compose.obs.yaml`, em vez de deixar o `:ro` dar uma falsa sensação de
  segurança.
- Quem não aceitar esse risco pode rodar sem cAdvisor: perde métricas por
  container e mantém as da aplicação e do host.
- O `node-exporter` tem um problema análogo, e maior — ele monta `/` do host em
  leitura. Está no mesmo profile opcional, pelo mesmo motivo.

## Alternativas consideradas

- **Não coletar métricas por container.** Recusada: é justamente o dado que
  responde "qual container estourou o limite de memória", que é metade do valor
  didático da observabilidade.
- **Métricas só via a aplicação.** Insuficiente: uma aplicação não consegue
  reportar o próprio OOM kill — ela morre antes.
