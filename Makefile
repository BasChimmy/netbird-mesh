# ─────────────────────────────────────────────────────────────
# Makefile — NetBird Mesh PoC (multi-case)
#
# Shared NetBird management plane lives at root (netbird/).
# Individual PoC cases live under poc/<case-name>/.
# ─────────────────────────────────────────────────────────────

SHELL := /bin/bash

.DEFAULT_GOAL := help

.PHONY: help netbird-up netbird-down teardown-all

help: ## Show this help
	@echo "NetBird mesh PoC — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "PoC cases (run make inside each folder):"
	@echo "  poc/k8s-statefulset/   — cross-cluster MariaDB via minikube"
	@echo "  poc/bastion-server/    — bastion routing peer to isolated VMs"

netbird-up: ## Start the shared NetBird management plane
	@./netbird/netbird-up.sh

netbird-down: ## Stop the shared NetBird management plane
	@docker compose -f netbird/docker-compose.yml down

teardown-all: ## Tear down everything (management + all PoC cases)
	@echo "Tearing down all PoC resources..."
	@cd poc/bastion-server && $(MAKE) down 2>/dev/null || true
	@cd poc/k8s-statefulset && $(MAKE) down 2>/dev/null || true
	@docker compose -f netbird/docker-compose.yml down -v 2>/dev/null || true
	@echo "All resources torn down."
