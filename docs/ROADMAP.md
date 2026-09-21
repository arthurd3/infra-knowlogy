# Roadmap — os módulos de infraestrutura

A tese do repositório não muda de módulo para módulo: **uma única aplicação real**
(o encurtador de URLs em `stack/services/`) atravessa toda a jornada de
infraestrutura, e cada módulo é uma *vista de deploy* dela — com um portão de
verificação próprio que prova, por comando, tudo o que as lições afirmam.

É a prescrição do [ADR 0001](adr/0001-compose-em-vez-de-kubernetes.md): módulos
novos **portam a mesma stack**, nunca introduzem uma aplicação nova. A comparação
lado a lado só é honesta porque a aplicação é a mesma.

| # | Módulo | Diretório | Portão | Estado |
|---|---|---|---|---|
| 1 | **Docker** — imagens, Compose, hardening OWASP, observabilidade | `stack/` | `make verify` (37 checagens) | **feito** · trilhas Fundamentos (8) e Produção (6) escritas |
| 2 | **Kubernetes** — a mesma stack portada para um cluster kind, agora com Gateway API, RBAC, HPA e PDB | `k8s/` | `make k8s-verify` (65 checagens) | **feito** · [ADR 0007](adr/0007-kind-e-o-porte-para-kubernetes.md) e [0021](adr/0021-gateway-api-e-o-envoy-gateway.md) · **10 lições bilíngues** · pendências: multi-nó (topologySpread, Cluster Autoscaler), VPA, service mesh, job de kind no CI |
| 3 | **CI/CD self-hosted (Jenkins)** — o mesmo pipeline do GitHub Actions rodando num Jenkins que é seu, sobre a mesma stack | `cicd/` | `make cicd-verify` (35 checagens) | **feito (v1)** · [ADR 0011](adr/0011-como-o-agente-de-build-constroi-imagens.md) e [0012](adr/0012-jenkins-conteinerizado.md) · 8 lições bilíngues · pendência: GitOps |
| 4 | **IaC (OpenTofu)** — a mesma stack declarada em HCL e provisionada contra o daemon local | `iac/` | `make iac-verify` (28 checagens) | **feito (v1)** · [ADR 0015](adr/0015-opentofu-e-o-provider-docker.md) e [0016](adr/0016-como-o-tofu-alcanca-o-daemon.md) · 8 lições bilíngues na trilha `iac` |
| 5 | **Configuração (Ansible)** — preparar um host Fedora real: Docker, SELinux, firewall, usuários — as coisas que o módulo 1 encontrou na marra | `config/` | a definir | reservado |
| 6 | **Observabilidade** — o profile `obs` que já existia, agora com regras de SLO que rodam e alerta de burn rate que dispara | `stack/` (profile) | `make verify` (passo 9, 9 checagens) | **feito (v1)** · [ADR 0018](adr/0018-slo-como-regra-que-roda.md) · 7 lições bilíngues na trilha `observabilidade` · pendências: Alertmanager e tracing |
| — | **Operação (transversal)** — o Linux por baixo do container, a rede que falha de um jeito só, e o Postgres que você opera | `stack/` | `make verify` (passo 10, 8 checagens) | **feito (v1)** · 7 lições bilíngues na trilha `operacao` · 4 chips do cartaz em `citado` |
| — | **Segurança (transversal)** — a superfície de ataque da MESMA stack, atacada de dentro: portas, credenciais, injeção, exfiltração | `tools/scripts/attack-lab.sh` | `make attack-lab` (11 ataques) | **feito** · [ADR 0013](adr/0013-laboratorio-de-ataque-na-propria-stack.md) · 6 lições bilíngues na trilha `seguranca` |

> **Por que a Segurança não tem número.** Os módulos numerados são *vistas de
> deploy* da mesma aplicação — Compose, Kubernetes, Jenkins. A trilha de
> Segurança não porta a stack para lugar nenhum: ela ataca a que já existe, em
> qualquer das vistas. Por isso ela é transversal, tem portão próprio
> (`make attack-lab`) e não reivindica um diretório de módulo.

## Regras que valem para qualquer módulo novo

1. **A aplicação é a de `stack/services/`.** Módulo novo = vista de deploy nova,
   nunca app nova.
2. **Todo módulo tem um portão** (`make <módulo>-verify`) no padrão do
   `verify.sh`: cada afirmação de lição vira uma checagem que falha alto.
   Os portões são independentes — quem estuda só Docker não instala kind.
3. **Toda lição nasce bilíngue** (PT-BR e EN, mesmo `key`) e ganha uma trilha
   própria no site (`track` novo em `TRACKS`, no `i18n/ui.ts`). Nasce também
   com **pelo menos um diagrama ou widget** e **pelo menos um exercício**
   (`Quiz` ou `LabExercise`) — e os dois idiomas usam os MESMOS componentes;
   `site/tests/content.test.ts` reprova quem esquecer qualquer um deles.
4. **Decisões viram ADR** — com as alternativas recusadas e o porquê.
5. **Números são medidos, nunca copiados** — cada módulo grava suas medições em
   `site/src/data/` e as lições citam o arquivo.
6. **Afirmação que não dá para medir aqui vive num `FieldNote`**, com fonte e
   data, e nunca solta na prosa (ADR 0009). Tradeoff sem critério de quando
   aplicar não é tradeoff — o teste reprova. Imagem de terceiro exige licença
   apurada e crédito visível (ADR 0010).

## O mapa de mercado

Desde setembro de 2026 este roadmap tem um **par medido**:
[`site/src/data/skills.json`](../site/src/data/skills.json) cruza o que 40 vagas
de SRE/DevOps pediam com o que este repositório prova por comando, e
`site/tests/skills.test.ts` reprova quem se declarar coberto apontando para uma
lição que não existe ou para uma checagem de portão que ninguém escreveu.

A prosa daqui explica o porquê; o JSON é quem não deixa envelhecer. Foi ele que
escolheu o módulo 4 — **IaC era o único item acima de 80% de demanda com zero
do lado de cá**. Ver o [ADR 0014](adr/0014-o-mapa-de-mercado-como-dado.md).

As maiores lacunas hoje, em ordem de demanda:

| Demanda | % | Estado |
|---|---|---|
| Observabilidade | 80% | **coberta**: 7 lições, regras de SLO rodando, alerta de burn rate provado pelo portão. Falta Alertmanager e tracing |
| Kubernetes | 88% | **coberta**: 10 lições, Gateway API roteando, RBAC provado por token real, HPA medido em 3 rodadas, PDB pela API de eviction, Helm × Kustomize comparados por diff. Falta o que um nó só não dá |
| CI/CD | 75% | forte, menos **GitOps**: ArgoCD e Flux não existem aqui |
| Linux & troubleshooting | 70% | **coberta**: namespaces, cgroup v2, OOM provocado e PSI medidos contra os containers. Falta perf e eBPF |
| Bancos & redes | 55% | **coberta**: vacuum, work_mem e pg_stat_statements medidos; a resolução de nome cronometrada de dentro do container. Falta replicação |
| Resiliência & operação | — | **7 de 7**: 3 chips `coberto` (Linux, redes, PostgreSQL) com checagem de portão, 4 `citado` (RCA, on-call, FinOps, IAM) com lição e fonte |

## A dívida didática, medida

Os primitivos de ensino foram inventados em ordem cronológica, e as trilhas
escritas antes nunca voltaram para usá-los. O retrato, contado por `grep` nos arquivos de lição em
setembro de 2026, depois de a trilha de Fundamentos ser retrabalhada
(ADR 0017) e de a de Kubernetes ser escrita:

| trilha | lições | `Term` | `Tradeoff` | `FieldNote` |
|---|---|---|---|---|
| seguranca | 6 | 13 | 3 | 9 |
| cicd | 9 | 18 | 6 | 5 |
| fundamentos | 8 | 15 | 1 | 1 |
| operacao | 8 | 10 | 8 | 8 |
| kubernetes | 11 | 13 | 11 | 11 |
| producao | 7 | 8 | 7 | 3 |
| observabilidade | 9 | 10 | 6 | 4 |
| iac | 8 | 6 | 7 | 7 |

Duas passadas de retrofit, e a dívida está paga. O Kubernetes era o pior caso e
era também a trilha mais curta — as duas coisas pelo mesmo motivo, e as duas
resolvidas juntas. Depois foi a vez do **cicd**, que tinha 9 lições e **um**
`Term`: hoje tem 18, dois por lição, mais 6 `Tradeoff` e 5 `FieldNote`.

**Nenhuma trilha tem lição sem conceito aberto**, e a `library.json` deixou de
cobrir três trilhas para cobrir **todas as 66 lições**, com 36 conceitos e 142
referências conferidas — os 25 links audiovisuais checados pelo título que o
YouTube devolve, porque id inventado responde 200 com página de erro.

## Itens dentro dos módulos já abertos

- **Módulo 1:** a Trilha Produção está **escrita**, com seis lições e não doze.
  A lista de doze é de agosto de 2026, quando o repositório tinha uma trilha
  só; auditando antes de escrever, **metade dela já tinha dono** — BuildKit na
  lição 4 de Fundamentos, PID 1 na 5, cadeia de suprimentos em `cicd-07`,
  observabilidade numa trilha inteira, e `_FILE` em onze lições. O
  [ADR 0019](adr/0019-reescopar-a-trilha-producao.md) registra a auditoria e o
  critério: só entrou o que o repositório TEM e ninguém ensinava.

  Os dois itens que ficaram de fora **foram feitos**: o **Alertmanager**
  ([ADR 0023](adr/0023-o-alerta-que-sai.md)), com roteamento, inibição,
  silenciamento e um receptor que registra a entrega; e o **tracing ponta a
  ponta** ([ADR 0024](adr/0024-tracing-e-o-que-ele-custa.md)), com um `trace_id`
  atravessando edge, api, a fila do Redis e o worker — e o custo medido contra
  uma imagem provadamente sem OTel (+63% na imagem da api, +88% no binário).
- **Módulo 4:** de pé e verde (28 checagens), com as 8 lições escritas. Ficou
  para depois: um backend remoto de verdade (com lock) para a lição 2 deixar de
  citar concorrência sem medi-la, e o espelho do módulo 2 — provisionar o
  cluster kind pelo OpenTofu, que é o arranjo mais comum na prática (a
  ferramenta provisiona o cluster, e o cluster reconcilia o que roda dentro).
- **Módulo 3:** de pé, verde (**35 checagens**) e com as **8 lições escritas**,
  incluindo os estágios `scan` (Trivy) e `sign` (cosign) — que este item dizia
  faltar até setembro de 2026, muito depois de existirem. Ficou de fora:
  **GitOps** (ArgoCD ou Flux), que é o chip de mercado que o módulo não cobre.

  O **GitOps** também saiu: ArgoCD v3.5.3 e Flux v2.9.5 no mesmo cluster,
  reconciliando o mesmo repositório, na lição `cicd-09` e no
  [ADR 0025](adr/0025-gitops-com-dois-reconciliadores.md). O portão afirma que o
  desvio é DESFEITO, nunca em quanto tempo — o `selfHeal` tem recuo exponencial,
  e juntar 0,34 s com 96 s numa mediana seria mentira.

  A assimetria da assinatura continua sendo a parte interessante e está na lição
  `cicd-07`: no GitHub Actions ela é keyless pelo OIDC do workflow; num Jenkins
  self-hosted custa uma chave gerenciada.
- **Segurança:** as 6 lições estão escritas e o portão está verde (10 ataques
  repelidos, o passo 6 vazando de propósito). Ficou para depois: um ataque de
  força bruta com taxa medida (hoje o passo 4 prova a recusa, não a velocidade),
  e o espelho do laboratório contra o cluster kind — as NetworkPolicies do
  módulo 2 dizem a mesma coisa que as redes do Compose e ninguém tentou
  atravessá-las ainda.
- **Módulo 2:** as **10 lições** estão escritas e a infraestrutura que elas
  ensinam existe: **Gateway API** (Envoy Gateway v1.9.1, [ADR 0021](adr/0021-gateway-api-e-o-envoy-gateway.md)),
  **RBAC** com sonda de token real, **HPA** com metrics-server, **PDB** provado
  pela API de eviction e um **chart Helm** comparado ao overlay Kustomize campo
  a campo. O portão foi de 33 para **65 checagens**.

  Ficou para depois, e quase tudo pela mesma razão — **este cluster tem um nó
  só**: `topologySpreadConstraints`, Cluster Autoscaler, VPA, service mesh,
  falha real de plano de controle e o job de kind no CI. O espelho do
  laboratório de ataque contra o cluster também continua aberto.

  > **Correção de rota.** Até setembro de 2026 esta linha dizia "Ingress de
  > verdade (ingress-nginx)". O projeto foi **aposentado em março de 2026**, e o
  > substituto que os próprios mantenedores anunciaram — o InGate — nunca
  > amadureceu e foi aposentado junto. A instrução antiga sobreviveu aqui por
  > onze meses sem que nada a contradissesse; é exatamente o tipo de
  > envelhecimento silencioso que o [ADR 0014](adr/0014-o-mapa-de-mercado-como-dado.md)
  > passou a impedir. O caminho seguido foi a **Gateway API**.
