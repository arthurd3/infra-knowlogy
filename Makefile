# infra-knowlogy — Módulo 1: Docker (stack/) · Módulo 2: Kubernetes (k8s/)
# `make` sozinho mostra esta ajuda. / `make` alone prints this help.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE      := docker compose -f stack/compose.yaml
COMPOSE_DEV  := $(COMPOSE) -f stack/compose.dev.yaml
COMPOSE_PROD := $(COMPOSE) -f stack/compose.prod.yaml
COMPOSE_OBS  := $(COMPOSE_PROD) -f stack/compose.obs.yaml --profile obs

# Todo Dockerfile do repositório, descoberto e não hardcoded.
DOCKERFILES := $(shell find stack site cicd -name Dockerfile -not -path '*/node_modules/*' 2>/dev/null)

.PHONY: help
help: ## Mostra esta ajuda / Show this help
	@echo ""
	@echo "  infra-knowlogy — Módulo 1: Docker · Módulo 2: Kubernetes"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── Ciclo de vida da stack / Stack lifecycle ────────────────────────────────

.PHONY: init
init: ## Gera stack/.env e os secrets locais a partir dos .example
	@bash tools/scripts/init-secrets.sh

.PHONY: up
up: init ## Sobe a stack endurecida (base + prod) e espera ficar saudável
	$(COMPOSE_PROD) up -d --wait
	@port=$$(grep -E '^EDGE_PORT=' stack/.env 2>/dev/null | cut -d= -f2); \
	printf '\n  site no ar: \033[36mhttp://127.0.0.1:%s\033[0m\n\n' "$${port:-8080}"

.PHONY: dev
dev: init ## Sobe em modo desenvolvimento com hot-reload (compose watch)
	$(COMPOSE_DEV) up --build --watch

.PHONY: obs
obs: init ## Sobe a stack + observabilidade (Prometheus/Grafana/Loki)
	$(COMPOSE_OBS) up -d --wait
	@port=$$(grep -E '^EDGE_PORT=' stack/.env 2>/dev/null | cut -d= -f2); \
	gport=$$(grep -E '^GRAFANA_PORT=' stack/.env 2>/dev/null | cut -d= -f2); \
	pport=$$(grep -E '^PROMETHEUS_PORT=' stack/.env 2>/dev/null | cut -d= -f2); \
	printf '\n  site no ar:  \033[36mhttp://127.0.0.1:%s\033[0m\n' "$${port:-8080}"; \
	printf '  grafana:     \033[36mhttp://127.0.0.1:%s\033[0m\n' "$${gport:-3000}"; \
	printf '  prometheus:  \033[36mhttp://127.0.0.1:%s\033[0m\n\n' "$${pport:-9090}"

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

# ─── Módulo Kubernetes / Kubernetes module ───────────────────────────────────
# Portão separado de propósito (ADR 0007): quem estuda só Docker não precisa
# de kind, e o estado bom conhecido do `verify` não muda.

KUBECONFORM := ghcr.io/yannh/kubeconform:v0.8.0@sha256:faffaf43f95aa6425306e1ab8d6fcad72acb9049158f38e574c085ea1ec0f64e

.PHONY: k8s-prereqs
k8s-prereqs: ## Checa kind/kubectl e diz como instalar no Fedora
	@bash tools/scripts/k8s-prereqs.sh

.PHONY: k8s-up
k8s-up: ## Sobe o cluster kind, carrega as imagens e aplica os manifests
	@bash tools/scripts/k8s-up.sh

.PHONY: k8s-down
k8s-down: ## Deleta o cluster kind (e tudo dentro dele)
	kind delete cluster --name infra-knowlogy
	rm -f k8s/.kubeconfig

.PHONY: k8s-lint
k8s-lint: ## Valida os manifests (kustomize + kubeconform), sem cluster
	@kubectl kustomize k8s/base | docker run --rm -i $(KUBECONFORM) -strict -summary -

.PHONY: k8s-verify
k8s-verify: ## O portão do módulo Kubernetes, end-to-end
	@bash tools/scripts/k8s-verify.sh

# ─── Módulo CI/CD / CI-CD module ─────────────────────────────────────────────
# Portão separado, como o do Kubernetes (ADR 0007). Quem estuda só Docker não
# instala Jenkins.

.PHONY: cicd-prereqs
cicd-prereqs: ## Checa o host e prova que dá para construir imagem sem daemon
	@bash tools/scripts/cicd-prereqs.sh

.PHONY: cicd-up
cicd-up: ## Sobe o Jenkins (controller, buildkitd, agente e registry)
	@bash tools/scripts/cicd-up.sh

.PHONY: cicd-down
cicd-down: ## Derruba o módulo CI/CD (mantém os volumes)
	docker compose -f cicd/compose.yaml down --remove-orphans

.PHONY: cicd-nuke
cicd-nuke: ## Derruba E apaga os volumes (jenkins_home, cache do buildkit, registry)
	docker compose -f cicd/compose.yaml down --remove-orphans --volumes

.PHONY: cicd-plugins
cicd-plugins: ## Atualiza as versões pinadas dos plugins do Jenkins
	@bash tools/scripts/update-jenkins-plugins.sh

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

.PHONY: site-test
site-test: ## Roda os testes do site (lógica dos widgets, paridade PT/EN)
	cd site && npm test

.PHONY: record-gate
record-gate: ## Regrava as respostas do modo demonstração do site (precisa da stack no ar)
	@bash tools/scripts/record-gate.sh

.PHONY: site-verify
site-verify: ## O portão só do site: tipos, testes, build e HTML gerado
	cd site && npm run check && npm test && npm run build
	@node tools/scripts/site-check.mjs

.PHONY: index
index: ## Indexa as lições na coleção Qdrant `infra-knowlogy`
	@uv run tools/scripts/index-qdrant.py
