# 0007 — kind e o porte para Kubernetes

**Estado:** aceita · **Data:** 2026-09-18

## Contexto

O [ADR 0001](0001-compose-em-vez-de-kubernetes.md) recusou Kubernetes no módulo
Docker, mas deixou a forma do retorno prescrita: "um módulo futuro sobre
orquestração deve portar esta mesma stack para Kubernetes, e não introduzir uma
stack nova". Este ADR registra as decisões desse porte (`k8s/`), que precisa
rodar na máquina de estudo (Fedora, Docker já instalado) e ser verificável por
um portão automatizado no padrão do `verify.sh`.

## Decisões

### 1. kind como cluster local

O cluster roda em **kind** (Kubernetes-in-Docker), com o nó `kindest/node`
pinado por digest como toda imagem do repositório (ADR 0004).

- O cluster vive **dentro de containers Docker** — que é exatamente o assunto do
  módulo 1. Nada é instalado no host além de dois binários estáticos
  (`kind`, `kubectl`); criar e destruir o cluster leva segundos, o que torna o
  portão (`make k8s-verify`) barato de rodar do zero.
- **Exigência dura: kind ≥ v0.23.0.** A partir dessa versão o kindnetd embute o
  `kube-network-policies` e passa a **aplicar** NetworkPolicy. Abaixo disso, as
  policies são aceitas pela API e ignoradas em silêncio — o pior tipo de mentira
  para um repositório cujas lições afirmam "o edge não alcança o db". O
  `k8s-prereqs.sh` recusa versões menores, e o portão prova o enforcement de
  qualquer jeito (uma conexão que deveria falhar tem que falhar).

### 2. Sem ingress controller: o próprio Caddy é o edge

O serviço `edge` (Caddy) vira um Deployment comum com Service **NodePort**,
mapeado pelo kind para `127.0.0.1:8081` via `extraPortMappings` — porta
diferente do 8080 do Compose de propósito: as lições comparam as duas stacks
**rodando ao mesmo tempo**.

O Caddyfile é o mesmo arquivo de `stack/services/edge/Caddyfile`, sem nenhuma
edição: ele fala com `api:8080` e `web:8080`, e Services com esses nomes
resolvem igual no DNS do cluster. Fonte única, zero drift.

### 3. YAML puro agregado por kustomization

Os manifests em `k8s/base/` são YAML puro, listados num `kustomization.yaml` e
aplicados com `kubectl apply -k` (o kustomize embutido no kubectl). Nenhuma
ferramenta extra, e o YAML que a lição mostra é o YAML que roda.

### 4. Portão separado: `make k8s-verify`

O módulo tem verificação própria (`tools/scripts/k8s-verify.sh`), independente
do `verify.sh`. O estado bom conhecido do módulo 1 (30 passaram · 0 falharam)
não muda, o tempo do `make verify` não dobra, e quem estuda só Docker não
precisa de kind. A única mudança no módulo 1 é a extração do smoke test para
`tools/scripts/lib/smoke.sh`, parametrizado por `BASEURL` — os dois portões
provam o MESMO fluxo (criar link → 302 → enriquecer → SSRF bloqueado) com o
mesmo código.

### 5. Secrets e ConfigMaps gerados, nunca versionados

O Secret do Postgres e os ConfigMaps (Caddyfile, SQL de init) são gerados pelo
`k8s-up.sh` a partir dos arquivos que já existem em `stack/` — os mesmos que o
Compose monta. A convenção `<VAR>_FILE` é preservada intacta: o Secret é montado
como arquivo em `/run/secrets/postgres_password` e `config.go`/`config.py` não
mudam uma linha.

## Consequências

- As lições podem afirmar, com medição: auto-cura, restart por liveness e
  rolling update sem downtime — as três coisas que o ADR 0001 listou como
  limites aceitos do Compose. As medições vão para
  `site/src/data/k8s-measured.json` (arquivo próprio; `measured.json` continua
  sendo reescrito só pelo `sizes.sh`).
- Sem ingress controller, não há lição de Ingress/IngressClass ainda — fica
  reservada no roadmap, introduzindo ingress-nginx quando chegar a vez (via API
  do Kubernetes com RBAC, não via docker.sock, então o ADR 0002 não é violado).
- As imagens locais entram no cluster com `kind load docker-image` e
  `imagePullPolicy: Never` — esquecer o load falha alto (`ErrImageNeverPull`)
  em vez de puxar outra coisa de um registry.
- O kubeconfig vive em `k8s/.kubeconfig` (ignorado pelo git); nenhum alvo do
  Makefile toca o `~/.kube/config` do usuário.

## Alternativas consideradas

- **minikube.** A opção clássica de estudo, com addons prontos. Recusada: mais
  pesada (driver/VM), mais lenta para criar/destruir, e os addons escondem
  exatamente as peças que as lições querem mostrar montadas à mão.
- **k3s.** Um Kubernetes real e enxuto — mas instala serviço no host, e a regra
  aqui é não poluir a máquina de estudo. O k3d (k3s em Docker) resolveria isso,
  porém com menos adoção e documentação que o kind, que é a ferramenta de teste
  do próprio projeto Kubernetes.
- **ingress-nginx desde já.** Não fere o ADR 0002 (usa a API com RBAC, não o
  socket), mas adiciona supply chain, RBAC e webhook de admissão antes de as
  três primeiras lições existirem. Adiada, não recusada.
- **Traefik como ingress.** Recusada por coerência com o ADR 0002 — e porque o
  Caddy já resolve com um arquivo que o leitor conhece do módulo 1.
- **Helm.** Templating esconde o YAML final, e o YAML final é o material
  didático. Recusada para este módulo.
- **configMapGenerator do kustomize para o Caddyfile.** Recusada: a *load
  restriction* do kustomize impede referenciar `stack/services/edge/Caddyfile`
  fora da raiz do kustomization, e copiar o arquivo criaria a segunda fonte de
  verdade que a decisão 5 existe para evitar.
