# 0026 — Malha de serviço, e por que ela não substitui a NetworkPolicy

**Estado:** aceita · **Data:** 2026-09-21

## Contexto

A trilha de Kubernetes já ensina NetworkPolicy, com enforcement provado: uma
conexão proibida **tem** que falhar, e a armadilha 48 mede até a janela em que a
policy ainda não vale num pod recém-criado (33 ms a 479 ms neste cluster).

O que a NetworkPolicy não responde é quem está do outro lado. Ela seleciona por
rótulo e endereço — e rótulo é atribuído por quem cria o pod, endereço é
reaproveitado. Num cluster onde alguém consegue criar pod com os rótulos certos,
a policy autoriza.

A afirmação mais repetida sobre service mesh é que ela custa latência. É uma
afirmação testável, e o repositório tem a régua para testar.

## Decisão

**Linkerd edge-26.9.3 no kind, com dois pares idênticos de serviços** — um em
namespace anotado com `linkerd.io/inject: enabled` e outro sem. A única
diferença entre os dois é a anotação, o que torna a comparação limpa.

A prova que importa não é o painel: é `tcpdump` dentro do pod mostrando tráfego
**cifrado** entre dois serviços que a aplicação nunca mandou cifrar, e a
identidade que o proxy apresenta sendo a **ServiceAccount**, não o IP:

```
default.linkerd-demo.serviceaccount.identity.linkerd.cluster.local
```

É essa a frase que fecha o argumento. A NetworkPolicy diz **quem pode falar**; o
mTLS diz **quem é quem**. As duas não se substituem, e a segunda é a que
sobrevive a um rótulo forjado.

## Consequências

**A latência medida contraria o senso comum.** Mediana com malha 0,64 ms contra
0,46 ms sem — **0,18 ms de diferença**. E no p95 a malha ficou *mais rápida*
(1,08 contra 1,63 ms), provavelmente por reuso de conexão no proxy.

A ressalva é parte do resultado: são dois pods no **mesmo nó**, com carga útil
trivial e um pedido por vez. Tráfego entre nós, payload grande e concorrência
alta mudam o número. O que a medição derruba não é "malha custa latência" em
geral — é a versão preguiçosa da afirmação, a que se repete sem número.

**O custo real é outro.** 3 MiB de memória por pod no sidecar (contra 10–12 MiB
do container da aplicação), um CLI de 87 MB, e um plano de controle inteiro para
operar. Quem adota uma malha paga em operação, não em milissegundos.

**Duas armadilhas medidas.** O `linkerd check --pre` reprova mandando instalar os
CRDs da **Gateway API**, e a mensagem não menciona Linkerd — o instalador passou
a instalar o Envoy Gateway antes, se os CRDs faltarem. E `linkerd install` **gera
uma PKI nova a cada execução**: reaplicar num cluster que já tem o plano de
controle troca a âncora de confiança e quebra a malha em silêncio, pod a pod,
conforme eles reiniciam. O instalador checa se o `linkerd-identity` existe antes.

**O que não foi feito.** Nada da stack de produção está na malha — os serviços
medidos existem para a medição. E não há política de autorização por identidade
(`Server`/`AuthorizationPolicy`), que é o passo em que a malha deixa de ser
observação e vira controle de acesso.
