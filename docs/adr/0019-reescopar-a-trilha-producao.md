# 0019 — Reescopar a Trilha Produção: de doze lições para seis

**Estado:** aceita · **Data:** 2026-09-20

## Contexto

O `docs/ROADMAP.md` prometia, desde **31 de agosto de 2026**, uma Trilha Produção
com doze lições:

> multi-stage nos três idiomas, BuildKit, PID 1 e sinais, hardening, segredos,
> rootless/Podman, observabilidade, cadeia de suprimentos, CI/CD, limites do
> Compose, 12-Factor.

A lista foi escrita quando o repositório tinha **uma trilha**. Desde então
nasceram quatro: Segurança, Kubernetes, CI/CD, IaC e Observabilidade. Antes de
escrever, auditamos a sobreposição por comando:

| tópico planejado | onde já está |
|---|---|
| BuildKit | 4 lições; `04-build-cache` é dona |
| PID 1 e sinais | 4 lições; `05-ciclo-de-vida` é dona |
| cadeia de suprimentos | 4 lições da trilha CI/CD; `cicd-07` é dona |
| observabilidade | **trilha inteira**, 7 lições |
| CI/CD | **trilha inteira**, 8 lições |
| segredos | **11 lições** mencionam `_FILE` — é o tópico mais repetido do repositório |
| limites do Compose | seção em `08-compose-e-healthchecks` e em `k8s-01` |

Metade da trilha planejada seria **duplicata**. Escrevê-la cumpriria o roadmap
ao pé da letra e faria o leitor que segue a ordem ler a mesma coisa duas vezes.

## Decisão

Seis lições, e o critério é **o que o repositório TEM e ninguém ensina**:

| # | lição | por que não era duplicata |
|---|---|---|
| 1 | três idiomas de multi-stage | três lições mencionam multi-stage; nenhuma **compara** as três linguagens |
| 2 | escolher a imagem base | seis lições mencionam distroless; nenhuma é dona da **escolha** |
| 3 | endurecer serviço a serviço | nove lições mencionam `read_only`/`cap_drop`; nenhuma lê o `compose.prod.yaml` inteiro |
| 4 | rootless e Podman | duas menções de passagem, ambas em outro contexto |
| 5 | os doze fatores auditados | **zero menções** no repositório inteiro |
| 6 | builds reprodutíveis | o `cicd-measured.json` mede e nenhuma lição explica |

Três delas passaram a existir porque a medição estava lá e a explicação não:
o `measured.json` já tinha **três variantes da mesma api** (scratch 5,1 MB,
distroless 5,7, alpine 8,9); o `cicd-measured.json` já registrava
`goBinaryIdentical: true` e `imageDigestIdentical: false`; e o `compose.prod.yaml`
já mostrava que dois dos seis serviços sobem com **zero capabilities**.

## O que a escrita mediu, e não estava medido antes

O Podman 5.8.4 estava instalado nesta máquina, então a lição 4 deixou de ser
citação e virou medição:

```
                     uid dentro    usuário no host
docker (rootful)     0             root
podman (rootless)    0             userlinux
```

E a aritmética do mapeamento é conferível: `/etc/subuid` concede
`userlinux:524288:65536`, então o `uid 65532` da imagem distroless vira
**589819** no host — que é `524288 + 65532 − 1`, e não um número alocado.

Também medido: porta 80 recusada sob rootless
(`net.ipv4.ip_unprivileged_port_start = 1024`), **zero** processos podman
residentes contra um `dockerd`, e a mesma imagem OCI rodando nas duas engines —
a api sobe no Podman e falha com o erro de configuração **dela mesma**.

## Alternativas recusadas

**Escrever as doze.** Honra o documento e produz seis lições redundantes. O
roadmap é um plano, não um contrato — e um plano de treze meses atrás que não é
revisado vira exatamente o que o ADR 0014 existe para impedir.

**Pular a trilha e ir para Kubernetes.** Kubernetes tem a pior dívida didática
(3 lições, zero `Term`, `Tradeoff` e `FieldNote`) e continua sendo a próxima
frente. Mas a Produção estava prometida desde agosto e tinha medições prontas
esperando explicação — adiá-la de novo aumentaria a dívida em vez de pagá-la.

## Consequências

- Trilha `producao`: 6 lições bilíngues, 6 diagramas, 6 quizzes.
- Quatro conceitos novos na `library.json` (ADR 0017), com o SLSA em vídeo e a
  tradução brasileira do 12-Factor.
- O ROADMAP passa a dizer **por que** doze virou seis, em vez de riscar itens.
- A regra que fica para o próximo módulo: **auditar a sobreposição antes de
  escrever**, e tratar item de roadmap antigo como hipótese a conferir.
