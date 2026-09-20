# 0015 — OpenTofu, e provisionar a própria stack em vez de nuvem

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

Este módulo nasceu de um cruzamento entre o que o repositório ensina e o que o
mercado pede. Num levantamento de 40 vagas de SRE/DevOps, **Terraform aparece
em 82%** — e era o único item de dois dígitos altos em que este repositório
marcava **zero**: o módulo 4 existia como uma linha reservada no roadmap e
nada mais.

Duas perguntas precisavam de resposta antes de escrever a primeira linha de
HCL: **qual das duas ferramentas**, e **provisionando o quê**.

## Decisão 1: OpenTofu, não Terraform

Em **10 de agosto de 2023** a HashiCorp mudou a licença do Terraform de MPL 2.0
para BUSL 1.1; a primeira versão sob a nova licença foi a **1.6.0, em 4 de
outubro de 2023**. BUSL é *source-available*, não open source — e o arquivo
`LICENSE` do Terraform escopa a BUSL para "Terraform Version 1.6.0 or later",
de modo que **toda versão atual** está sob ela.

A resposta da comunidade foi o fork **OpenTF**, renomeado **OpenTofu** em 20 de
setembro de 2023 ao ser aceito pela Linux Foundation, e que permanece MPL 2.0 e
aprovado pela OSI. Em 2025 a IBM concluiu a aquisição da HashiCorp.

Escolhemos o OpenTofu por três razões, nesta ordem:

1. **Licença.** Um repositório didático que se diz de infraestrutura aberta não
   deveria ensinar com uma ferramenta que o leitor não pode usar livremente no
   trabalho dele sem ler uma cláusula de concorrência primeiro.
2. **Há um recurso que só ele tem, e ele é o assunto de uma lição.** A
   **cifragem de estado** chegou no OpenTofu 1.7 (abril de 2024), com
   `key_provider` PBKDF2, AWS KMS, GCP KMS, Azure Vault e OpenBao. O CLI open
   source do Terraform não tem equivalente nativo; a resposta dele foi outra —
   `ephemeral` (1.10, nov/2024) e argumentos *write-only* (1.11, fev/2025),
   que impedem o segredo de CHEGAR ao estado em vez de cifrar o estado. As
   duas abordagens resolvem problemas diferentes e a lição `secrets-in-state`
   ensina as duas, medindo a primeira.
3. **Compatibilidade.** A linguagem é a mesma, os providers são os mesmos, e o
   que se aprende aqui se usa num Terraform sem tradução. Quem só viu vaga
   pedindo "Terraform" não perde nada.

Versão pinada: **OpenTofu 1.12.3**, imagem oficial
`ghcr.io/opentofu/opentofu`, pinada por digest como toda imagem daqui
(ADR 0004).

### Alternativa recusada: Pulumi, CDK, Crossplane

São desenhos legítimos e **não** são o que as vagas pedem. Um módulo didático
que ensina a ferramenta minoritária para provar um ponto de gosto não serve ao
leitor. Ficam como assunto de um `Tradeoff` dentro da lição 1.

## Decisão 2: o provider Docker, contra a MESMA stack

O [ADR 0001](0001-compose-em-vez-de-kubernetes.md) prescreve a forma de todo
módulo novo: **portar a mesma aplicação**, nunca introduzir outra. O módulo 2
portou para o kind; o 3 levou o build para um Jenkins próprio. O módulo 4
provisiona, com `kreuzwerker/docker` 4.6.0, os mesmos seis serviços, três
redes e quatro volumes do `stack/compose.yaml`.

O ganho é a comparação direta: o portão roda o **mesmo `lib/smoke.sh`** contra
a porta 8082 e prova que é a mesma aplicação. E a trilha inteira ganha um eixo
que nenhuma outra tem — Compose, Kubernetes e OpenTofu descrevendo o mesmo
desenho, com três modelos de reconciliação diferentes.

### Alternativa recusada: LocalStack

Ensinaria VPC, EC2, S3 e IAM sem gastar. Recusada porque **o que o portão
mediria seria o LocalStack, não a AWS** — e a diferença entre os dois é
exatamente onde moram os erros que importam. Uma lição que diz "o security
group bloqueou" quando quem bloqueou foi um simulador mente com a cara limpa,
e este repositório existe para o contrário disso.

### Alternativa recusada: nuvem de verdade

Fiel ao que as vagas pedem pelo nome, e incompatível com o princípio inegociável
daqui: toda afirmação verificável por um comando **nesta máquina**. Exigiria
conta, cartão e um portão que ninguém roda duas vezes.

## O preço desta decisão, declarado

O módulo **não prova**, e as lições não podem fingir que provam:

| O que fica de fora | Por quê | Como entra na lição |
|---|---|---|
| VPC, subnet, security group, IAM | não existem no daemon local | `FieldNote` com fonte e data |
| Remote state com lock (S3 + DynamoDB, ou o lock nativo em S3 do OpenTofu 1.12) | o backend aqui é arquivo local | `FieldNote` |
| Custo, e o que um `destroy` errado custa | não há fatura | `FieldNote` |
| Workspaces e módulos compartilhados em equipe | é prática de time, não de ferramenta | `Tradeoff` |

E há um limite da própria ferramenta que **foi medido aqui** e vale mais que os
quatro de cima: o provider Docker **não tem `pids_limit`**. O
`compose.prod.yaml` põe `deploy.resources.limits.pids: 200` em todo serviço, e
essa linha de endurecimento **não é expressável** neste provider. É a lição que
um módulo de IaC honesto tem que dar: um provider é um **mapeamento parcial** de
uma API, e descobrir qual pedaço falta é trabalho de quem adota.

## Consequências

- Diretório `iac/`, portão `make iac-verify` (**28 checagens**), medições em
  `site/src/data/iac-measured.json`.
- A stack do módulo 4 atende em **127.0.0.1:8082** — 8080 é o Compose, 8081 o
  kind, 8090 o Jenkins. As quatro convivem, e o portão prova que a do Compose
  atravessa o `iac-verify` intacta.
- Os portões continuam independentes (ADR 0007): quem estuda só Docker não
  instala OpenTofu.
