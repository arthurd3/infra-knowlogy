# As três redes do compose.yaml, declaradas de novo — e a `data` continua
# `internal`, que é o que deixa o Postgres e o Redis sem NENHUMA rota para
# fora. A checagem 5 do `make verify` prova a mesma coisa do lado do Compose.
#
# Os nomes levam o prefixo `iac-` de propósito: as três vistas de deploy sobem
# ao mesmo tempo na mesma máquina, e a lição `drift-and-reconciliation` compara
# as três lado a lado.

locals {
  # Um rótulo em tudo. É ele que responde "o que este módulo criou?" sem
  # depender do estado — e é assim que o portão prova que o destroy não
  # deixou sobra (checagem 17).
  labels = {
    "infra-knowlogy.module" = var.module_label
  }
}

resource "docker_network" "edge" {
  name   = "iac-edge"
  driver = "bridge"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_network" "data" {
  name   = "iac-data"
  driver = "bridge"

  # Sem gateway. Quem só está aqui não alcança a internet nem a rede do host;
  # exfiltrar dados do banco exige antes comprometer alguém que esteja nas
  # duas redes — que é exatamente o desenho do worker.
  internal = true

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_network" "egress" {
  name   = "iac-egress"
  driver = "bridge"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── Volumes ─────────────────────────────────────────────────────────────────
# Volumes NOMEADOS, como no Compose: o Docker é dono do ciclo de vida e o I/O
# é nativo. `for_each` em vez de quatro blocos iguais — e repare que a chave do
# for_each vira parte do ENDEREÇO do recurso (docker_volume.data["pgdata"]),
# o que faz o plano falar em nomes e não em índices.

resource "docker_volume" "data" {
  for_each = toset(["pgdata", "redisdata", "caddy_data", "caddy_config"])

  name = "iac-${each.key}"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}
