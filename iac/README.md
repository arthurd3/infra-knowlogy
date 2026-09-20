# Módulo 4 — IaC com OpenTofu

A mesma stack do módulo 1, declarada em HCL e provisionada pelo **OpenTofu**
contra o daemon do Docker desta máquina. Nenhuma conta em nuvem, nenhum custo —
e, ainda assim, `state`, `plan`, grafo de dependências, drift e cifragem de
estado todos medidos de verdade.

As decisões estão no [ADR 0015](../docs/adr/0015-opentofu-e-o-provider-docker.md)
(por que OpenTofu e não Terraform; por que o provider Docker e não LocalStack)
e no [ADR 0016](../docs/adr/0016-como-o-tofu-alcanca-o-daemon.md) (como o `tofu`
alcança o socket sob SELinux, e o que isso custa).

```bash
make iac-prereqs   # sonda: como o tofu alcança o daemon nesta máquina
make iac-up        # provisiona a stack em 127.0.0.1:8082
make iac-plan      # o que mudaria, sem mudar nada
make iac-verify    # o portão — 28 checagens. Estado bom: 28 passaram · 0 falharam
make iac-down      # tofu destroy
```

Iteração rápida: `KEEP_STACK=1 make iac-verify` (não destrói no fim) e
`SKIP_NEGATIVE=1` (pula a prova do lock adulterado, que reinstala o provider).

## Os arquivos

| Arquivo | O que tem |
|---|---|
| `versions.tf` | `required_version` e o provider pinado por versão — o `.terraform.lock.hcl` pina por hash |
| `variables.tf` | tudo que muda de máquina; nenhum segredo, só **caminhos** de segredo |
| `networks.tf` | as três redes (a `data` é `internal`) e os quatro volumes, por `for_each` |
| `containers.tf` | os seis serviços, com o endurecimento do `compose.prod.yaml` |
| `outputs.tf` | o endereço e os ids, para o portão não adivinhar |
| `demo-secret/` | demonstração **deliberada** de vazamento de segredo no estado |

## O que este módulo prova

O portão roda o **mesmo `tools/scripts/lib/smoke.sh`** que o `verify.sh` e o
`k8s-verify.sh` rodam. É isso que sustenta a tese do repositório: três vistas de
deploy, uma aplicação. Com `make up`, `make k8s-up` e `make iac-up` no ar ao
mesmo tempo, o mesmo fluxo passa em 8080, 8081 e 8082.

Além disso:

- **idempotência** — `plan` logo depois do `apply` sai `0`;
- **drift** — apagar um container à mão faz o `plan -refresh-only` sair `2` e
  **nomear** o recurso;
- **grafo** — a aresta `api → db` é **implícita** (nasceu de `POSTGRES_HOST`
  referenciar o recurso) e a `edge → api` é **explícita** (`depends_on`, porque
  quem nomeia a api é o Caddyfile, um arquivo que o `tofu` não lê);
- **pin** — um `.terraform.lock.hcl` com os hashes adulterados **reprova** o
  `init`;
- **estado** — a senha do Postgres **não** aparece nele (a convenção
  `<VAR>_FILE` passa o caminho, não o valor), e a demonstração ao lado prova o
  que acontece quando o segredo entra na configuração: ele vai para o arquivo,
  em texto puro, até alguém ligar a cifragem.

## Duas coisas que o portão pegou, e que ninguém esperava

**`CAP_CHOWN`, não `CHOWN`.** O Docker 29 normaliza o nome da capability para a
forma canônica com prefixo. Escrito sem ele, o provider lê de volta um valor
diferente do que escreveu e **todo** `plan` seguinte pede `replace` dos quatro
containers que usam `capabilities.add` — para sempre, sem ninguém ter mexido em
nada. Os dois que só têm `drop = ["ALL"]` ficavam estáveis, o que mandava
procurar o defeito no lugar errado.

**`memory_swap`.** Sem `--memory-swap`, o daemon grava `2 × memory` do lado
dele. O provider lê 1024 de volta, a configuração não diz nada, e o `plan` pede
`memory_swap = 1024 -> null` eternamente. Atributo não declarado não é atributo
sem valor.

As duas só aparecem se alguém rodar `plan` **depois** do `apply` e exigir zero.
É a razão de a checagem de idempotência existir.
