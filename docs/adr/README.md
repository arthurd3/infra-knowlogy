# Architecture Decision Records

Registros das decisões que não são óbvias a partir do código — e, principalmente,
das **alternativas recusadas** e do porquê. Quando alguém (você daqui a seis
meses, ou um agente lendo o repositório) perguntar "por que não usaram Traefik?",
a resposta está aqui e não perdida num chat.

Estes documentos são **internos**, escritos só em português. O conteúdo bilíngue
é o das lições em `site/src/content/lessons/`; um ADR é uma nota de engenharia,
não material didático.

| # | Decisão | Estado |
|---|---|---|
| [0001](0001-compose-em-vez-de-kubernetes.md) | Compose em vez de Kubernetes | aceita |
| [0002](0002-caddy-em-vez-de-traefik.md) | Caddy em vez de Traefik | aceita |
| [0003](0003-socket-do-docker-na-observabilidade.md) | Como lidar com o socket do Docker | aceita |
| [0004](0004-pin-por-digest.md) | Pinar imagens base por digest | aceita |
| [0005](0005-stack-poliglota.md) | Stack poliglota (Go + Python + Node) | aceita |
| [0006](0006-excecoes-de-scanner-com-prazo.md) | Exceções de scanner com prazo de validade | aceita |
| [0007](0007-kind-e-o-porte-para-kubernetes.md) | kind e o porte para Kubernetes | aceita |
| [0008](0008-acoes-ao-vivo-no-site-estatico.md) | Ações ao vivo num site que continua estático | aceita |
| [0009](0009-afirmacao-medida-e-afirmacao-citada.md) | Afirmação medida e afirmação citada | aceita |
| [0010](0010-imagens-de-terceiros.md) | Imagens de terceiros no site | aceita |
| [0011](0011-como-o-agente-de-build-constroi-imagens.md) | Como o agente de build constrói imagens | aceita |
| [0012](0012-jenkins-conteinerizado.md) | Jenkins conteinerizado, ao lado do GitHub Actions | aceita |
| [0013](0013-laboratorio-de-ataque-na-propria-stack.md) | Ensinar segurança atacando a própria stack | aceita |
| [0014](0014-o-mapa-de-mercado-como-dado.md) | O mapa de mercado como dado verificável | aceita |
| [0015](0015-opentofu-e-o-provider-docker.md) | OpenTofu, e provisionar a própria stack em vez de nuvem | aceita |
| [0016](0016-como-o-tofu-alcanca-o-daemon.md) | Como o `tofu` alcança o daemon, e o que isso custa | aceita |
| [0017](0017-a-trilha-de-estudo-e-as-fontes.md) | A trilha de estudo, e por que ela não é o `sources:` | aceita |
| [0018](0018-slo-como-regra-que-roda.md) | SLO como regra que roda, e não como capítulo | aceita |
| [0019](0019-reescopar-a-trilha-producao.md) | Reescopar a Trilha Produção: de doze lições para seis | aceita |
