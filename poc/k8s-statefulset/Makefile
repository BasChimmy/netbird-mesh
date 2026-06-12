# ─────────────────────────────────────────────────────────────
# Makefile — PoC: K8s StatefulSet (cross-cluster MariaDB via NetBird)
# ─────────────────────────────────────────────────────────────

SHELL := /bin/bash
SCRIPTS := scripts
DEVOPS_IMAGE ?= netbird-poc/devops-server:latest

.DEFAULT_GOAL := help

.PHONY: help restart-handson down

help: ## Show this help
	@echo "PoC: k8s-statefulset — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

restart-handson: ## Reset for a fresh HANDSON.md run
	@echo "Resetting k8s-statefulset PoC..."
	@../../scripts/teardown.sh --purge --yes 2>/dev/null || true
	@docker image rm -f $(DEVOPS_IMAGE) >/dev/null 2>&1 || true
	@echo "Clean slate ready. Start over from HANDSON.md Step 1."

down: ## Tear down clusters and devops container
	@../../scripts/teardown.sh --yes 2>/dev/null || true
