terraform {
  required_version = ">= 1.12.0"

  required_providers {
    docker = {
      # Registry do OpenTofu, explícito. Sem o host o `tofu` assumiria
      # `registry.opentofu.org` de qualquer jeito, mas declarar deixa claro
      # que este módulo NÃO depende do registry da HashiCorp.
      source  = "registry.opentofu.org/kreuzwerker/docker"
      version = "4.6.0"
    }
  }
}
