# As entradas do módulo. Tudo o que muda de máquina para máquina mora aqui —
# e NENHUMA delas é segredo: a senha do Postgres entra como CAMINHO de arquivo,
# nunca como valor, exatamente como no compose.yaml e no config.go.

variable "edge_port" {
  description = "Porta publicada em 127.0.0.1. 8080 é o Compose, 8081 o kind, 8090 o Jenkins."
  type        = number
  default     = 8082
}

variable "postgres_db" {
  type    = string
  default = "links"
}

variable "postgres_user" {
  type    = string
  default = "links"
}

variable "postgres_password_file" {
  description = <<-EOT
    Caminho NO HOST do arquivo de senha. O mesmo que o `make init` gera para o
    Compose: os módulos compartilham a convenção, não copiam o segredo.

    Repare que o que entra é o caminho, e não a senha. Mesmo assim ela VAI
    parar no estado — ver a lição `secrets-in-state` e a checagem 12 do portão.
  EOT
  type        = string
  default     = "../stack/secrets/postgres_password"
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "redis_maxmemory" {
  type    = string
  default = "128mb"
}

variable "module_label" {
  description = "Rótulo em todo recurso. É por ele que o portão prova que nada vazou."
  type        = string
  default     = "iac"
}

# ─── Imagens base, pinadas por digest ────────────────────────────────────────
# Os mesmos digests do stack/compose.yaml. Tag é ponteiro mutável (ADR 0004);
# quem atualiza os dois é o `make pins`, nunca a mão.

variable "image_caddy" {
  type    = string
  default = "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
}

variable "image_postgres" {
  type    = string
  default = "postgres:17-alpine@sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73"
}

variable "image_redis" {
  type    = string
  default = "redis:7-alpine@sha256:ff02b58f971e7d7d156a1267e283fcbbeee91773b6aa36c49dac28ecfe28eadf"
}

variable "host_repo_root" {
  description = <<-EOT
    Caminho do repositório NO HOST.

    Existe porque há dois sistemas de arquivos em jogo quando o `tofu` roda
    conteinerizado: o CONTEXTO DE BUILD é lido pelo processo do tofu (caminho
    do container), enquanto o `host_path` de um bind mount é resolvido pelo
    DAEMON (caminho do host). Rodando o tofu no host os dois coincidem, e é
    justamente por isso que o erro só aparece na outra via.

    O tools/scripts/lib/tofu.sh preenche isto via TF_VAR_host_repo_root.
  EOT
  type        = string
}
