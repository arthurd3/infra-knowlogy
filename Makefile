# infra-knowlogy — Módulo 1: Docker
# `make` sozinho mostra esta ajuda. / `make` alone prints this help.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE      := docker compose -f stack/compose.yaml
COMPOSE_DEV  := $(COMPOSE) -f stack/compose.dev.yaml
COMPOSE_PROD := $(COMPOSE) -f stack/compose.prod.yaml
COMPOSE_OBS  := $(COMPOSE_PROD) -f stack/compose.obs.yaml --profile obs

# Todo Dockerfile do repositório, descoberto e não hardcoded.
DOCKERFILES := $(shell find stack site -name Dockerfile -not -path '*/node_modules/*' 2>/dev/null)

.PHONY: help
help: ## Mostra esta ajuda / Show this help
	@echo ""
	@echo "  infra-knowlogy — Módulo 1: Docker"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Ciclo de vida da stack / Stack lifecycle ────────────────────────────────

.PHONY: init
init: ## Gera stack/.env e os secrets locais a partir dos .example
	@bash tools/scripts/init-secrets.sh

.PHONY: up
up: init ## Sobe a stack endurecida (base + prod) e espera ficar saudável
	$(COMPOSE_PROD) up -d --wait

.PHONY: dev
dev: init ## Sobe em modo desenvolvimento com hot-reload (compose watch)
	$(COMPOSE_DEV) up --build --watch

.PHONY: obs
obs: init ## Sobe a stack + observabilidade (Prometheus/Grafana/Loki)
	$(COMPOSE_OBS) up -d --wait

.PHONY: down
down: ## Derruba a stack (mantém os volumes)
	$(COMPOSE_OBS) down --remove-orphans

.PHONY: nuke
nuke: ## Derruba a stack E apaga os volumes (perde os dados)
	$(COMPOSE_OBS) down --remove-orphans --volumes

.PHONY: ps
ps: ## Lista os serviços e o estado de saúde de cada um
	$(COMPOSE_PROD) ps

.PHONY: logs
logs: ## Segue os logs de todos os serviços
	$(COMPOSE_PROD) logs -f --tail=100

.PHONY: build
build: ## Builda todas as imagens da stack
	$(COMPOSE_PROD) build

# ─── Qualidade / Quality ─────────────────────────────────────────────────────

.PHONY: verify
verify: ## Roda a verificação completa end-to-end (o portão de qualidade)
	@bash tools/scripts/verify.sh

.PHONY: lint
lint: ## Roda o hadolint em todos os Dockerfiles e valida os compose files
	@for f in $(DOCKERFILES); do \
		echo "── hadolint $$f"; \
		docker run --rm -i hadolint/hadolint:latest hadolint --no-color - < "$$f" || exit 1; \
	done
	@echo "── docker compose config"
	@$(COMPOSE_OBS) config -q && echo "compose OK"

.PHONY: scan
scan: ## Escaneia todas as imagens com Trivy (falha em HIGH/CRITICAL)
	@bash tools/scripts/scan.sh

.PHONY: sizes
sizes: ## Mede o tamanho real das imagens -> site/src/data/measured.json
	@bash tools/scripts/sizes.sh

.PHONY: shutdown-test
shutdown-test: ## Prova que todo serviço para graciosamente em menos de 3s
	@bash tools/scripts/shutdown-test.sh

.PHONY: pins
pins: ## Atualiza os digests sha256 das imagens base
	@bash tools/scripts/update-pins.sh

# ─── Site didático / Teaching site ───────────────────────────────────────────

.PHONY: site-install
site-install: ## Instala as dependências do site
	cd site && npm install

.PHONY: site-dev
site-dev: ## Roda o site de lições localmente (sem Docker)
	cd site && npm run dev

.PHONY: site-build
site-build: ## Builda o site estático
	cd site && npm run build

.PHONY: index
index: ## Indexa as lições na coleção Qdrant `infra-knowlogy`
	@uv run tools/scripts/index-qdrant.py
