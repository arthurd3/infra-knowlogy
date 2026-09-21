# 0025 — GitOps com dois reconciliadores, e o que o portão pode afirmar

**Estado:** aceita · **Data:** 2026-09-21

## Contexto

O repositório já tinha **três** modelos de desvio medidos: o Compose (que não
reconcilia nada), o Kubernetes (cujos controladores reconciliam o estado do
cluster contra o que a API guarda) e o OpenTofu (que reconcilia contra um arquivo
de estado, quando alguém roda o comando).

Faltava o quarto, e é o que a lição `drift-and-reconciliation` não tinha como
completar: um controlador que reconcilia o cluster contra o **Git**,
continuamente, sem ninguém rodar nada.

A escolha entre ArgoCD e Flux costuma ser apresentada como preferência de
interface. Ela não é: os dois têm arquiteturas diferentes de disparo, e isso
muda o que cada um promete.

## Decisão

**Os dois, no mesmo cluster, reconciliando o mesmo repositório** — e o portão
afirmando o que DÁ para afirmar.

O `k8s-gitops-install.sh` instala ArgoCD v3.5.3 e Flux v2.9.5, ambos com
manifesto pinado por sha256 no padrão do [ADR 0021](0021-gateway-api-e-o-envoy-gateway.md).
O ArgoCD aponta para `k8s/base`; o Flux, para `gitops/flux-demo`. Com os dois de
pé a comparação deixa de ser leitura de documentação e passa a ser medição — o
mesmo método do comparador de Helm × Kustomize.

**A decisão difícil foi sobre o que a checagem afirma.** A primeira versão
cronometrava quanto o ArgoCD levava para desfazer uma mudança manual. O número
não se sustentou:

| provocação | tempo até desfazer |
|---|---|
| primeira depois de uma sincronização limpa | **0,34 s** (duas vezes) |
| de seguida | 11,1 s · 48,1 s |
| contínua | platô de **~96 s** |
| depois de uma pausa de 90 s | 26,1 s — **não zerou** |

O `selfHeal` tem recuo exponencial, e é de propósito: um controlador em laço de
briga martelaria o API server. Juntar esses números numa mediana seria mentira —
não são amostras da mesma grandeza.

Então o portão afirma **que desfaz**, com um orçamento de 300 s e uma linha de
base `Synced` antes de provocar. Nunca em quanto tempo.

## Consequências

**O que isto compra.** A quarta coluna da tabela de desvio, e uma lição que
compara duas arquiteturas com medição em vez de preferência. E a descoberta de
que o modelo de credencial é o argumento que importa: no modelo de empurrar, o
CI guarda a chave do cluster; no de puxar, o cluster busca, e o CI não precisa
de credencial nenhuma.

**Um defeito real encontrado.** O ArgoCD ficou permanentemente `OutOfSync` no
StatefulSet do banco. Duas tentativas de `ignoreDifferences` não testaram nada
porque o bloco nunca esteve no nível de indentação certo. A resposta veio de
perguntar ao próprio ArgoCD: `/api/v1/applications/<app>/managed-resources` traz
`normalizedLiveState` e `predictedLiveState`, que é o que ele de fato compara — e
a diferença eram **duas linhas**: `apiVersion` e `kind` ausentes dentro do
`volumeClaimTemplate`. A correção foi no manifesto, não no controlador: o objeto
passou a descrever o que o API server preenche de qualquer jeito.

Recurso que nunca sincroniza treina a equipe a ignorar o painel inteiro, e é por
isso que a correção certa não era um `ignoreDifferences`.

**O que não foi feito.** Nenhum dos dois gerencia a stack de produção deste
repositório — eles reconciliam o cluster kind. E não há promoção entre ambientes
nem `ApplicationSet`: o assunto da lição é o laço, não a topologia de entrega.
