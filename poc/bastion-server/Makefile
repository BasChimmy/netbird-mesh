# ─────────────────────────────────────────────────────────────
# Makefile — PoC: Bastion Server (NetBird routing peer to isolated VMs)
# ─────────────────────────────────────────────────────────────

SHELL := /bin/bash
SCRIPTS := scripts

.DEFAULT_GOAL := help

.PHONY: help up down test restart clean

help: ## Show this help
	@echo "PoC: bastion-server — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Bring up the full PoC (bootstrap + containers + routes)
	@$(SCRIPTS)/up.sh

down: ## Tear down containers (keep NetBird API resources)
	@$(SCRIPTS)/teardown.sh

test: ## Run connectivity + isolation test
	@$(SCRIPTS)/test-connectivity.sh

restart: down up ## Tear down and bring back up

clean: ## Full teardown including NetBird API resources
	@$(SCRIPTS)/teardown.sh --purge
