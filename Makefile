# Convenience wrapper around the common commands. `make help` lists them.
# These are shortcuts only — every target maps to a plain docker/compose command
# you should understand (see the docs/ guides).

.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help init certs htpasswd up up-mon down logs ps models smoke stats clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: ## First-time setup: .env + certs + htpasswd
	@test -f .env || cp .env.example .env
	@bash scripts/gen-certs.sh
	@bash scripts/gen-htpasswd.sh admin admin
	@echo "Init done. Edit .env if you want, then run: make up"

certs: ## (Re)generate the self-signed TLS certificate
	@bash scripts/gen-certs.sh

htpasswd: ## (Re)generate basic-auth file (USER/PASS vars optional)
	@bash scripts/gen-htpasswd.sh $(or $(USER),admin) $(or $(PASS),admin)

up: ## Start the core stack (ollama, ocr, search, milvus, nginx)
	docker compose up -d --build

up-mon: ## Start core + monitoring stack
	docker compose --profile monitoring up -d --build

down: ## Stop everything (keeps volumes/data)
	docker compose --profile monitoring down

logs: ## Tail logs of all services (Ctrl-C to stop)
	docker compose logs -f --tail=100

ps: ## Show container status + health
	docker compose ps

models: ## Pull the LLM + embedding models into Ollama
	bash scripts/pull-models.sh

smoke: ## Run the end-to-end smoke test through the gateway
	bash scripts/smoke-test.sh

stats: ## Live CPU/RAM per container
	docker stats

clean: ## DANGER: stop and delete all containers AND volumes (data loss)
	docker compose --profile monitoring down -v
