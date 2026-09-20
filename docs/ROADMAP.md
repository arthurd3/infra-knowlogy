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
| 1 | **Docker** — imagens, Compose, hardening OWASP, observabilidade | `stack/` | `make verify` (32 checagens) | **feito** · pendência: Trilha Produção (12 lições) |
| 2 | **Kubernetes** — a mesma stack portada para um cluster kind | `k8s/` | `make k8s-verify` (33 checagens) | **feito (v1)** · [ADR 0007](adr/0007-kind-e-o-porte-para-kubernetes.md) · pendências: lições 4+, Gateway API, HPA, RBAC, kind no CI |
| 3 | **CI/CD self-hosted (Jenkins)** — o mesmo pipeline do GitHub Actions rodando num Jenkins que é seu, sobre a mesma stack | `cicd/` | `make cicd-verify` (35 checagens) | **feito (v1)** · [ADR 0011](adr/0011-como-o-agente-de-build-constroi-imagens.md) e [0012](adr/0012-jenkins-conteinerizado.md) · pendências: as 8 lições, scan e assinatura no pipeline |
| 4 | **IaC (OpenTofu)** — a mesma stack declarada em HCL e provisionada contra o daemon local | `iac/` | `make iac-verify` (28 checagens) | **feito (v1)** · [ADR 0015](adr/0015-opentofu-e-o-provider-docker.md) e [0016](adr/0016-como-o-tofu-alcanca-o-daemon.md) · 8 lições bilíngues na trilha `iac` |
| 5 | **Configuração (Ansible)** — preparar um host Fedora real: Docker, SELinux, firewall, usuários — as coisas que o módulo 1 encontrou na marra | `config/` | a definir | reservado |
| 6 | **Observabilidade avançada** — SLOs, alerting e tracing por cima do profile `obs` já existente | `stack/` (profile) | a definir | reservado |
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
| Observabilidade | 80% | a infra roda (`make obs`) e **não há uma lição sequer** — é a frente mais barata |
| Kubernetes | 88% | 3 lições de ~10; falta Gateway API, Helm, RBAC, HPA |
| CI/CD | 75% | forte, menos **GitOps**: ArgoCD e Flux não existem aqui |
| Linux & troubleshooting | 70% | falta o troubleshooting real: /proc, strace, eBPF, PSI, OOM |
| Bancos & redes | 55% | falta operação do Postgres e DNS a fundo |
| Resiliência & operação | — | **0%**: SLO, error budget, postmortem, on-call, FinOps, IAM |

## A dívida didática, medida

Os primitivos de ensino foram inventados em ordem cronológica, e as trilhas
escritas antes nunca voltaram para usá-los. O retrato, em setembro de 2026,
depois de a trilha de Fundamentos ser retrabalhada (ADR 0017):

| trilha | lições | `Term` | `Tradeoff` | `FieldNote` |
|---|---|---|---|---|
| fundamentos | 8 | 15 | 1 | 1 |
| seguranca | 6 | 13 | 3 | 9 |
| **kubernetes** | 3 | **0** | **0** | **0** |
| **cicd** | 8 | **0** | 1 | 1 |
| iac | 8 | 6 | 7 | 7 |

O Kubernetes é o pior caso e é também a trilha mais curta — as duas coisas pelo
mesmo motivo. A `library.json` hoje cobre só os conceitos de Fundamentos;
estendê-la para as outras trilhas é trabalho declarado, não esquecido.

## Itens dentro dos módulos já abertos

- **Módulo 1:** Trilha Produção — 12 lições sobre o código que já existe
  (multi-stage nos três idiomas, BuildKit, PID 1 e sinais, hardening, segredos,
  rootless/Podman, observabilidade, cadeia de suprimentos, CI/CD, limites do
  Compose, 12-Factor).
- **Módulo 4:** de pé e verde (28 checagens), com as 8 lições escritas. Ficou
  para depois: um backend remoto de verdade (com lock) para a lição 2 deixar de
  citar concorrência sem medi-la, e o espelho do módulo 2 — provisionar o
  cluster kind pelo OpenTofu, que é o arranjo mais comum na prática (a
  ferramenta provisiona o cluster, e o cluster reconcilia o que roda dentro).
- **Módulo 3:** a infraestrutura está de pé e o portão verde (32 checagens).
  Faltam **as 8 lições** da trilha `cicd`, e dois estágios no pipeline: `scan`
  (Trivy) e `sign` (cosign). A assinatura é a parte interessante — no GitHub
  Actions ela é keyless pelo OIDC do workflow; num Jenkins self-hosted custa
  uma chave gerenciada, e essa assimetria é o assunto de uma das lições.
- **Segurança:** as 6 lições estão escritas e o portão está verde (10 ataques
  repelidos, o passo 6 vazando de propósito). Ficou para depois: um ataque de
  força bruta com taxa medida (hoje o passo 4 prova a recusa, não a velocidade),
  e o espelho do laboratório contra o cluster kind — as NetworkPolicies do
  módulo 2 dizem a mesma coisa que as redes do Compose e ninguém tentou
  atravessá-las ainda.
- **Módulo 2:** depois das 3 lições iniciais — **Gateway API**, StatefulSets a
  fundo, HPA/VPA, RBAC e um job de kind no CI (o nome fica reservado aqui até o
  portão estabilizar localmente).

  > **Correção de rota.** Até setembro de 2026 esta linha dizia "Ingress de
  > verdade (ingress-nginx)". O projeto foi **aposentado em março de 2026**, e o
  > substituto que os próprios mantenedores anunciaram — o InGate — nunca
  > amadureceu e foi aposentado junto. O caminho hoje é a **Gateway API**, GA
  > desde outubro de 2023. A instrução antiga sobreviveu aqui por onze meses
  > sem que nada a contradissesse; é exatamente o tipo de envelhecimento
  > silencioso que o [ADR 0014](adr/0014-o-mapa-de-mercado-como-dado.md) passou
  > a impedir.
