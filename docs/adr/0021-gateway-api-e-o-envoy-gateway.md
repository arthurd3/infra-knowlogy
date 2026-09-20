# 0021 — Gateway API, e por que o controlador é o Envoy Gateway

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O `docs/ROADMAP.md` pedia "Ingress de verdade (ingress-nginx)" desde agosto de
2026. A instrução envelheceu mentindo: o **ingress-nginx foi aposentado em março
de 2026**, e o sucessor anunciado pelos próprios mantenedores — o InGate — foi
aposentado junto, sem nunca amadurecer. A correção de rota já estava registrada
no roadmap; faltava executá-la.

O caminho vivo é a **Gateway API**, GA desde outubro de 2023, hoje na v1.6.2. E
ela não é "Ingress com outro nome": é uma resposta a um problema
**organizacional**, não técnico.

O Ingress era UM objeto onde cabiam host, caminho, TLS, serviço de destino e —
na prática — vinte anotações específicas do controlador. Quem opera o cluster e
quem desenvolve a aplicação editavam o mesmo YAML. Não havia como dar a um time
de produto o direito de acrescentar um caminho sem lhe dar, junto, o direito de
trocar o certificado curinga.

A Gateway API parte isso em três objetos e três papéis: `GatewayClass` (quem
fornece a infraestrutura), `Gateway` (quem opera o cluster) e `HTTPRoute` (quem
desenvolve a aplicação). A separação é operacionalizável — dá para escrever RBAC
que concede HTTPRoute e nega Gateway.

## Decisão

Instalar a Gateway API com o **Envoy Gateway v1.9.1**, publicar a stack numa
segunda porta (`127.0.0.1:8083`, ao lado dos 8081 do `edge`) e provar o **mesmo
fluxo** pelos dois caminhos, com o `run_smoke` compartilhado.

O manifesto não é versionado; é **baixado e conferido por sha256**, pinado em
`k8s/addons/gateway-pins.json`.

## Alternativas recusadas

**NGINX Gateway Fabric.** É a sucessão natural do ingress-nginx na narrativa e
foi a primeira escolha. Recusada por uma razão operacional: o **NGF v2 deixou de
publicar manifesto avulso** — as URLs de `crds.yaml` e `nginx-gateway-fabric.yaml`
devolvem 404, e a instalação só existe via chart Helm. Isso põe o Helm entre o
leitor e a primeira rota funcionando, numa lição cujo assunto não é Helm. O
Envoy Gateway publica um `install.yaml` único que um `kubectl apply` resolve.

**Versionar os manifests.** O `install.yaml` do Envoy Gateway tem **3,98 MB** e
os CRDs avulsos da Gateway API, **1,17 MB**. Quatro megabytes de YAML gerado
para provar uma rota é um mau negócio para um repositório cujo material se lê
no navegador. O `metrics-server`, de 4 KB, foi versionado justamente porque
cabia — o critério é tamanho, não princípio.

**Baixar sem conferir.** Recusada sem hesitação. `v1.9.1` é uma tag, e tag é
mutável. O sha256 faz por um manifesto exatamente o que o digest faz por uma
imagem no [ADR 0004](0004-pin-por-digest.md): ou o conteúdo é o mesmo, ou o
portão para e diz qual hash esperava.

**Substituir o `edge` pelo Gateway.** Os dois coexistem de propósito. O `edge` é
o caminho do módulo 1 — um Caddy que a stack carrega consigo, que funciona em
Compose, em Kubernetes e sob OpenTofu. O Gateway é o caminho nativo do cluster.
Mantê-los lado a lado, servindo a mesma aplicação ao mesmo tempo, é o que
permite comparar os dois sem hipótese.

## Consequências

**Uma armadilha nova, e é das boas.** Sem a NetworkPolicy que autoriza o proxy,
o Gateway fica **inteiramente verde** — `Programmed=True`, `Accepted=True`,
`ResolvedRefs=True`, `attachedRoutes=1` — e nenhuma requisição completa. O
pacote é descartado (não recusado), então o cliente pendura até o timeout em vez
de levar `connection refused`, e não há erro em log nenhum do lado da aplicação.
Quem conta a verdade é o log de acesso do Envoy: `"response_flags": "DC"`,
`"bytes_received": 0`, com o upstream CERTO escolhido.

É a [armadilha 13](../../CLAUDE.md) na escala do Gateway: status de objeto mede
o plano de **controle**. Nada no Gateway sabe que NetworkPolicy existe. O portão
reproduz isso de propósito — apaga a policy, mostra o verde convivendo com o
timeout, e restaura.

**Casar não é reescrever.** O `handle_path /r/*` do Caddy **remove** o prefixo;
a HTTPRoute encaminha o caminho intacto. O primeiro teste deu 404 vindo da api,
com a rota casando corretamente. A correção é o filtro `URLRewrite` com
`ReplacePrefixMatch` — que é de nível **Extended** na conformidade da Gateway
API, e não Core. Essa graduação é, ela mesma, o avanço prático sobre o Ingress:
existe um nome para "esta funcionalidade é opcional", em vez de uma anotação que
funciona num controlador e é ignorada em silêncio noutro.

**Uma porta de nó fixa.** O kind declara mapeamento de porta na **criação** do
cluster, então o `nodePort` do Service do Envoy precisa ser fixo (30081) em vez
de sorteado. Isso sai pelo `parametersRef` do `GatewayClass` apontando para um
`EnvoyProxy` — que é, de novo, a válvula de escape com schema que a
especificação oferece no lugar das anotações.

**O portão depende da rede uma vez.** O download é cacheado em `k8s/.cache/` e
revalidado pelo hash a cada execução — cache conferido, não confiado. Sem rede e
sem cache, a seção da Gateway falha alto em vez de fingir; `SKIP_GATEWAY=1`
desliga.
