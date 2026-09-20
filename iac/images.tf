# As imagens. Três vêm pinadas por digest do registry; três são construídas
# aqui, dos MESMOS Dockerfiles que o Compose constrói.
#
# `target` é explícito em todas as três. Sem ele o builder constrói a ÚLTIMA
# stage do arquivo — que no site é a `dev`, com Node e `astro dev`. O container
# sobe, serve o site, e só em produção alguém descobre. É a armadilha 9 do
# CLAUDE.md, e ela não muda de ferramenta: o Compose tem o mesmo buraco.

locals {
  repo_root = abspath("${path.module}/..")
}

resource "docker_image" "base" {
  for_each = {
    caddy    = var.image_caddy
    postgres = var.image_postgres
    redis    = var.image_redis
  }

  name = each.value

  # Sem isto, um `tofu destroy` apaga do host imagens que outros módulos deste
  # repositório usam — o Compose e o kind puxam exatamente estes digests.
  keep_locally = true
}

resource "docker_image" "built" {
  for_each = {
    api    = { context = "${local.repo_root}/stack/services/api-go", target = "dist" }
    worker = { context = "${local.repo_root}/stack/services/worker-py", target = "dist" }
    web    = { context = "${local.repo_root}/site", target = "dist" }
  }

  name         = "infra-knowlogy/${each.key}:iac"
  keep_locally = true

  build {
    context = each.value.context
    target  = each.value.target
    tag     = ["infra-knowlogy/${each.key}:iac"]

    label = local.labels
  }

  # O provider guarda o id da imagem no estado e só reconstrói se algo aqui
  # mudar. Ele NÃO observa o conteúdo do contexto: editar um .go não dispara
  # rebuild sozinho. É uma diferença real para o `docker compose build`, e a
  # lição `plan-and-apply` a mede.
  triggers = {
    dockerfile = filesha256("${each.value.context}/Dockerfile")
  }
}
