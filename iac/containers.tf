# Os seis serviços do compose.yaml, declarados em HCL.
#
# A comparação com o `stack/compose.yaml` é o ponto do módulo inteiro, e ela
# NÃO é "um é melhor". São três diferenças de natureza:
#
#   1. O Compose tem `x-` e âncoras YAML; aqui o que se repete vira `locals`
#      e `dynamic`. O Compose repete o bloco de endurecimento seis vezes.
#   2. O Compose tem `secrets:` de primeira classe; aqui é bind mount explícito
#      — que é EXATAMENTE o que o Compose faz por baixo fora do Swarm
#      (armadilha 8 do CLAUDE.md). A ferramenta só parou de esconder.
#   3. O Compose tem `deploy.resources.limits.pids`; o provider Docker NÃO tem
#      `pids_limit`. Um provider é um mapeamento PARCIAL da API, e descobrir
#      qual pedaço falta é trabalho de quem adota, não detalhe.

locals {
  # O endurecimento que vale para todos (compose.prod.yaml: &hardened).
  no_new_privs = ["no-new-privileges:true"]

  # O segredo, resolvido para caminho absoluto NO HOST — é o daemon que o
  # abre, não o processo do tofu. Ver a variável host_repo_root.
  secret_file = "${var.host_repo_root}/stack/secrets/postgres_password"

  # Onde o segredo aparece DENTRO do container. O mesmo caminho do Compose,
  # porque o config.go e o config.py leem <VAR>_FILE e não sabem (nem devem
  # saber) qual ferramenta subiu o container.
  secret_mount = "/run/secrets/postgres_password"
}

# ─── Banco ───────────────────────────────────────────────────────────────────

resource "docker_container" "db" {
  name  = "iac-db"
  image = docker_image.base["postgres"].image_id

  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=${var.postgres_db}",
    "POSTGRES_USER=${var.postgres_user}",
    # O valor NÃO passa por aqui. Só o caminho — a mesma convenção do Compose,
    # do config.go e do config.py.
    "POSTGRES_PASSWORD_FILE=${local.secret_mount}",
    # Sem isto o initdb usa `trust` para conexão local: qualquer processo
    # dentro do container entra no banco sem senha.
    "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256",
  ]

  volumes {
    volume_name    = docker_volume.data["pgdata"].name
    container_path = "/var/lib/postgresql/data"
  }

  volumes {
    host_path      = "${var.host_repo_root}/stack/services/db/init"
    container_path = "/docker-entrypoint-initdb.d"
    read_only      = true
    # O equivalente do `:z` do Compose. O provider expõe como atributo; sem
    # ele, sob SELinux enforcing, o Postgres recebe permission denied num
    # arquivo 644 e a mensagem não menciona SELinux (armadilha 2).
    selinux_relabel = "z"
  }

  volumes {
    host_path       = local.secret_file
    container_path  = local.secret_mount
    read_only       = true
    selinux_relabel = "z"
  }

  networks_advanced {
    name    = docker_network.data.name
    aliases = ["db"]
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U ${var.postgres_user} -d ${var.postgres_db} -q"]
    interval     = "5s"
    timeout      = "5s"
    retries      = 10
    start_period = "30s"
  }

  # O apply só volta quando o healthcheck passa. É o equivalente do
  # `depends_on: {condition: service_healthy}` do Compose — mas repare que
  # aqui quem espera é o LADO DE CÁ, e não o container seguinte.
  wait         = true
  wait_timeout = 120

  read_only = true
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=64m"
    # O socket unix do Postgres vive aqui, e o rootfs está read-only.
    "/run/postgresql" = "rw,noexec,nosuid,size=8m"
  }

  security_opts = local.no_new_privs

  capabilities {
    drop = ["ALL"]
    # O entrypoint do Postgres começa como root, acerta o dono do diretório de
    # dados e só então faz setuid. Sem estas cinco ele não passa do boot — o
    # exemplo perfeito de por que `cap_drop: [ALL]` cego quebra imagem oficial.
    #
    # ── E por que `CAP_CHOWN` e não `CHOWN` ──────────────────────────────────
    # O Compose aceita as duas formas. Aqui, NÃO: o daemon normaliza o nome
    # para a forma canônica com prefixo, e devolve `CAP_CHOWN` no inspect.
    # Escrito sem o prefixo, o provider lê de volta um valor diferente do que
    # escreveu, e o plan seguinte pede REPLACE do container — para sempre.
    #
    # Medido neste repositório com Docker 29.7.2: um `tofu apply` seguido de
    # `tofu plan` acusava "4 to add, 2 to change, 4 to destroy" sem ninguém ter
    # tocado em nada. Só os quatro containers com `add` entravam na conta; os
    # dois que só têm `drop = ["ALL"]` ficavam estáveis, o que mandava procurar
    # o defeito no lugar errado.
    #
    # A checagem de idempotência do portão (plan pós-apply tem que sair 0) é o
    # que pega isto. É a razão de ela existir.
    add = ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER", "CAP_SETGID", "CAP_SETUID"]
  }

  # ── memory_swap declarado de propósito ──────────────────────────────────────
  # O daemon aplica um default do lado DELE: sem `--memory-swap`, ele grava
  # 2 × memory. O provider lê 1024 de volta, a config não diz nada, e o plan
  # seguinte pede `memory_swap = 1024 -> null` — para sempre, sem ninguém ter
  # mexido em nada.
  #
  # É a mesma família do defeito das capabilities acima, e a lição é a mesma:
  # atributo NÃO declarado não é atributo sem valor. Quando o outro lado tem
  # um default, ou você o declara, ou o plan nunca converge.
  memory      = 512
  memory_swap = 1024
  cpus        = "1.0"

  ulimit {
    name = "nofile"
    soft = 4096
    hard = 4096
  }

  destroy_grace_seconds = 30

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── Cache ───────────────────────────────────────────────────────────────────

resource "docker_container" "cache" {
  name  = "iac-cache"
  image = docker_image.base["redis"].image_id

  restart = "unless-stopped"

  command = [
    "redis-server",
    "--save", "60", "1",
    "--appendonly", "no",
    "--maxmemory", var.redis_maxmemory,
    "--maxmemory-policy", "allkeys-lru",
  ]

  volumes {
    volume_name    = docker_volume.data["redisdata"].name
    container_path = "/data"
  }

  networks_advanced {
    name    = docker_network.data.name
    aliases = ["cache"]
  }

  healthcheck {
    test         = ["CMD", "redis-cli", "ping"]
    interval     = "5s"
    timeout      = "3s"
    retries      = 5
    start_period = "5s"
  }

  wait         = true
  wait_timeout = 60

  read_only     = true
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,size=16m" }
  security_opts = local.no_new_privs

  capabilities {
    drop = ["ALL"]
    add  = ["CAP_SETGID", "CAP_SETUID"]
  }

  # O maxmemory do Redis é o limite LÓGICO; este é o físico, com folga para o
  # alocador. Iguais, o OOM killer chegaria antes da evicção do Redis agir.
  memory      = 192
  memory_swap = 384
  cpus        = "0.5"

  destroy_grace_seconds = 10

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── API ─────────────────────────────────────────────────────────────────────

resource "docker_container" "api" {
  name  = "iac-api"
  image = docker_image.built["api"].image_id

  restart = "unless-stopped"

  env = [
    "LISTEN_ADDR=:8080",
    "BASE_URL=http://localhost:${var.edge_port}/r",
    # ── A dependência IMPLÍCITA ──────────────────────────────────────────────
    # Isto não é decoração: referenciar `docker_container.db.name` cria uma
    # ARESTA no grafo. O `tofu graph` mostra db -> api, e o apply respeita a
    # ordem sem que ninguém a tenha escrito. Trocar por "iac-db" literal
    # funcionaria igual… até o dia em que o nome mudasse.
    "POSTGRES_HOST=${docker_container.db.name}",
    "POSTGRES_DB=${var.postgres_db}",
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD_FILE=${local.secret_mount}",
    "REDIS_HOST=${docker_container.cache.name}",
    "LOG_LEVEL=${var.log_level}",
  ]

  volumes {
    host_path       = local.secret_file
    container_path  = local.secret_mount
    read_only       = true
    selinux_relabel = "z"
  }

  networks_advanced {
    name = docker_network.edge.name
    # O Caddyfile diz `reverse_proxy api:8080`. O container se chama `iac-api`,
    # então sem este alias o edge resolveria nada. O Compose dava o alias de
    # graça, pelo nome do serviço.
    aliases = ["api"]
  }

  networks_advanced {
    name = docker_network.data.name
  }

  # Sem bloco healthcheck de propósito: a instrução HEALTHCHECK já está na
  # imagem (services/api-go/Dockerfile) e o container a herda. O `wait` abaixo
  # usa essa saúde. Declarar de novo aqui seria espalhar a definição de saúde
  # por mais um lugar — o oposto do que o módulo 2 aprendeu (armadilha 11).
  wait         = true
  wait_timeout = 90

  read_only     = true
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,size=16m" }
  security_opts = local.no_new_privs

  capabilities {
    # Binário estático, distroless, USER 65532, sem bind em porta privilegiada.
    # Não precisa de capability nenhuma.
    drop = ["ALL"]
  }

  memory      = 256
  memory_swap = 512
  cpus        = "1.0"

  ulimit {
    name = "nofile"
    soft = 8192
    hard = 8192
  }

  destroy_grace_seconds = 15

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── Worker ──────────────────────────────────────────────────────────────────

resource "docker_container" "worker" {
  name  = "iac-worker"
  image = docker_image.built["worker"].image_id

  restart = "unless-stopped"

  env = [
    "POSTGRES_HOST=${docker_container.db.name}",
    "POSTGRES_DB=${var.postgres_db}",
    "POSTGRES_USER=${var.postgres_user}",
    "POSTGRES_PASSWORD_FILE=${local.secret_mount}",
    "REDIS_HOST=${docker_container.cache.name}",
    "LOG_LEVEL=${upper(var.log_level)}",
  ]

  volumes {
    host_path       = local.secret_file
    container_path  = local.secret_mount
    read_only       = true
    selinux_relabel = "z"
  }

  # Duas redes: `data` para falar com o banco e o cache, `egress` para
  # conseguir baixar as páginas. O db e o cache NÃO estão na egress — se o
  # worker for comprometido ele tem saída, o banco não.
  networks_advanced {
    name = docker_network.data.name
  }

  networks_advanced {
    name = docker_network.egress.name
  }

  # Sem bloco `healthcheck` aqui: a imagem do worker traz a instrução
  # HEALTHCHECK (services/worker-py/Dockerfile), e o container a herda — o
  # mesmo arranjo da api. Por isso o `wait` abaixo tem o que esperar.
  #
  # Se a imagem NÃO tivesse healthcheck, `wait = true` faria o provider errar:
  # ele exige saúde declarada em algum lugar para ter o que observar.
  wait         = true
  wait_timeout = 90

  read_only     = true
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,size=64m" }
  security_opts = local.no_new_privs

  capabilities {
    drop = ["ALL"]
  }

  memory      = 384
  memory_swap = 768
  cpus        = "1.0"

  destroy_grace_seconds = 30

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── Site estático ───────────────────────────────────────────────────────────

resource "docker_container" "web" {
  name  = "iac-web"
  image = docker_image.built["web"].image_id

  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.edge.name
    aliases = ["web"]
  }

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--spider", "http://127.0.0.1:8080/"]
    interval     = "15s"
    timeout      = "3s"
    retries      = 3
    start_period = "5s"
  }

  wait         = true
  wait_timeout = 90

  read_only     = true
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,size=32m" }
  security_opts = local.no_new_privs

  capabilities {
    drop = ["ALL"]
    # Mesma imagem Caddy do edge: o binário carrega
    # `cap_net_bind_service=+ep` como file capability, e o kernel recusa o
    # exec() se ela não estiver no bounding set — mesmo publicando em 8080.
    add = ["CAP_NET_BIND_SERVICE", "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"]
  }

  memory      = 128
  memory_swap = 256
  cpus        = "0.5"

  destroy_grace_seconds = 10

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ─── Proxy de borda ──────────────────────────────────────────────────────────

resource "docker_container" "edge" {
  name  = "iac-edge"
  image = docker_image.base["caddy"].image_id

  restart = "unless-stopped"

  env = [
    "SITE_ADDRESS=:8080",
    "AUTO_HTTPS=off",
  ]

  ports {
    internal = 8080
    external = var.edge_port
    # 127.0.0.1 obrigatório. Sem o ip, o Docker escreve DNAT na tabela nat do
    # iptables, avaliada ANTES do firewalld — e a porta fica aberta para a
    # internet inteira com o firewall "ativo". Regra 5a da OWASP.
    ip = "127.0.0.1"
  }

  volumes {
    host_path       = "${var.host_repo_root}/stack/services/edge/Caddyfile"
    container_path  = "/etc/caddy/Caddyfile"
    read_only       = true
    selinux_relabel = "z"
  }

  volumes {
    volume_name    = docker_volume.data["caddy_data"].name
    container_path = "/data"
  }

  volumes {
    volume_name    = docker_volume.data["caddy_config"].name
    container_path = "/config"
  }

  networks_advanced {
    name = docker_network.edge.name
  }

  # ── A dependência EXPLÍCITA, e por que esta precisa ser escrita ────────────
  # O edge não referencia nada da api nem do web: quem os nomeia é o Caddyfile,
  # um arquivo que o tofu não lê. Sem dado fluindo entre os recursos não há
  # aresta implícita — e o grafo subiria os três em paralelo, deixando o Caddy
  # tentando resolver `api` antes de o container existir.
  #
  # `depends_on` é a exceção honesta, não o padrão. Quando dá para criar a
  # aresta por referência (como em POSTGRES_HOST), é melhor.
  depends_on = [
    docker_container.api,
    docker_container.web,
  ]

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--spider", "http://127.0.0.1:8080/edge-health"]
    interval     = "10s"
    timeout      = "3s"
    retries      = 3
    start_period = "5s"
  }

  wait         = true
  wait_timeout = 90

  read_only     = true
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,size=32m" }
  security_opts = local.no_new_privs

  capabilities {
    drop = ["ALL"]
    add  = ["CAP_NET_BIND_SERVICE", "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"]
  }

  memory      = 128
  memory_swap = 256
  cpus        = "0.5"

  destroy_grace_seconds = 10

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}
