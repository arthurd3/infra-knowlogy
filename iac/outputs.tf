# As saídas. Existem para duas coisas: o portão lê o `edge_url` em vez de
# recalcular a porta, e o `tofu output -json` é a interface de quem for
# encadear este módulo com outro.

output "edge_url" {
  description = "Onde a stack do módulo 4 atende. 8080 é o Compose, 8081 o kind."
  value       = "http://127.0.0.1:${var.edge_port}"
}

output "containers" {
  description = "Nome e id de cada container, para o portão conferir sem adivinhar."
  value = {
    for k, c in {
      db     = docker_container.db
      cache  = docker_container.cache
      api    = docker_container.api
      worker = docker_container.worker
      web    = docker_container.web
      edge   = docker_container.edge
    } : k => { name = c.name, id = c.id }
  }
}

output "networks" {
  value = {
    edge   = docker_network.edge.name
    data   = docker_network.data.name
    egress = docker_network.egress.name
  }
}

output "module_label" {
  description = "O par label=valor que responde 'o que este módulo criou?' sem ler o estado."
  value       = "infra-knowlogy.module=${var.module_label}"
}

# A senha NÃO é output. Um `output` marcado `sensitive` continua indo para o
# estado em texto puro — esconder da tela não é esconder do arquivo, e a
# lição `secrets-in-state` mede exatamente isso.
