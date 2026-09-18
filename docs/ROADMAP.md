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
| 1 | **Docker** — imagens, Compose, hardening OWASP, observabilidade | `stack/` | `make verify` (30 checagens) | **feito** · pendências: Trilha Produção (12 lições), widget de topologia, demo do `docker history` |
| 2 | **Kubernetes** — a mesma stack portada para um cluster kind | `k8s/` | `make k8s-verify` (33 checagens) | **feito (v1)** · [ADR 0007](adr/0007-kind-e-o-porte-para-kubernetes.md) · pendências: lições 4+, Ingress, HPA, kind no CI |
| 3 | **CI/CD self-hosted (Jenkins)** — rodar em um Jenkins conteinerizado o pipeline que hoje vive no GitHub Actions (lint → build → scan → assinatura), sobre a mesma stack, comparando os dois mundos | `cicd/` | a definir | reservado |
| 4 | **IaC (Terraform/OpenTofu)** — provisionar o host (ou o cluster) que os módulos 1–2 assumem existir | `iac/` | a definir | reservado |
| 5 | **Configuração (Ansible)** — preparar um host Fedora real: Docker, SELinux, firewall, usuários — as coisas que o módulo 1 encontrou na marra | `config/` | a definir | reservado |
| 6 | **Observabilidade avançada** — SLOs, alerting e tracing por cima do profile `obs` já existente | `stack/` (profile) | a definir | reservado |

## Regras que valem para qualquer módulo novo

1. **A aplicação é a de `stack/services/`.** Módulo novo = vista de deploy nova,
   nunca app nova.
2. **Todo módulo tem um portão** (`make <módulo>-verify`) no padrão do
   `verify.sh`: cada afirmação de lição vira uma checagem que falha alto.
   Os portões são independentes — quem estuda só Docker não instala kind.
3. **Toda lição nasce bilíngue** (PT-BR e EN, mesmo `key`) e ganha uma trilha
   própria no site (`track` novo no enum).
4. **Decisões viram ADR** — com as alternativas recusadas e o porquê.
5. **Números são medidos, nunca copiados** — cada módulo grava suas medições em
   `site/src/data/` e as lições citam o arquivo.

## Itens dentro dos módulos já abertos

- **Módulo 1:** Trilha Produção — 12 lições sobre o código que já existe
  (multi-stage nos três idiomas, BuildKit, PID 1 e sinais, hardening, segredos,
  rootless/Podman, observabilidade, cadeia de suprimentos, CI/CD, limites do
  Compose, 12-Factor).
- **Módulo 2:** depois das 3 lições iniciais — Ingress de verdade
  (ingress-nginx), StatefulSets a fundo, HPA, e um job de kind no CI (o nome
  fica reservado aqui até o portão estabilizar localmente).
