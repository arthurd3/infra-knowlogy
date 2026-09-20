# ─── Demonstração DELIBERADA: o segredo que entra na configuração ────────────
#
# Este diretório NÃO faz parte da stack. Ele existe para provar, por comando,
# a afirmação central da lição `secrets-in-state` — e para provar também o que
# a corrige.
#
# O módulo de verdade (iac/) passa só o CAMINHO do arquivo de senha para o
# container, nunca o valor: é a convenção <VAR>_FILE que o config.go e o
# config.py implementam. Consequência direta: **a senha não aparece no estado**,
# porque o tofu nunca a lê.
#
# O erro comum é o oposto — puxar o segredo para dentro da configuração, com
# `file()`, com um `random_password`, ou com uma variável. Aí ele vira atributo
# de recurso, e todo atributo de recurso vai para o estado, em texto puro.
#
# `terraform_data` é um recurso embutido, sem provider e sem efeito colateral:
# ele guarda o que você mandar guardar. É o experimento mais limpo possível —
# nada além do estado está em jogo.

variable "password_file" {
  description = "Caminho do arquivo de senha, relativo a este módulo."
  type        = string
  default     = "../../stack/secrets/postgres_password"
}

resource "terraform_data" "leaked" {
  # O jeito ERRADO, de propósito. `sensitive = true` numa variável esconderia
  # o valor da SAÍDA do plan — e não mudaria uma vírgula do que segue abaixo.
  input = file(var.password_file)
}

output "proof" {
  description = "Quantos bytes entraram no estado. O valor em si não é impresso."
  value       = "o estado agora contém ${length(file(var.password_file))} bytes de segredo"
}
