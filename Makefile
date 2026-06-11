# ─────────────────────────────────────────────────────────────
# Makefile — NetBird Mesh PoC
#
# This PoC is designed to be followed step-by-step via HANDSON.md.
# The only automation target is `restart-handson` which resets
# the environment so you can practice the hands-on guide again.
# ─────────────────────────────────────────────────────────────

SHELL := /bin/bash
SCRIPTS := scripts

# Matches the default in scripts/config.sh; override on the CLI if changed.
DEVOPS_IMAGE ?= netbird-poc/devops-server:latest

.DEFAULT_GOAL := help

.PHONY: help restart-handson

help: ## Show this help
	@echo "NetBird mesh PoC — available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

restart-handson: ## Reset to a clean slate so you can practice HANDSON.md again
	@echo "Resetting environment for a fresh HANDSON.md run..."
	@$(SCRIPTS)/teardown.sh --purge --yes
	@echo "Removing the DevOps server image (HANDSON.md rebuilds it in Step 9)..."
	@docker image rm -f $(DEVOPS_IMAGE) >/dev/null 2>&1 || true
	@echo ""
	@echo "Clean slate ready. The /etc/hosts entry for netbird.local is kept"
	@echo "(it survives across runs). Start over from HANDSON.md Step 1."
