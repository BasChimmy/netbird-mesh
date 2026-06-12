#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# FILE:    config.sh (bastion-server POC)
# PURPOSE: POC-specific configuration. Sources the shared config first,
#          then adds bastion-server-specific values.
# USAGE:   source "$(dirname "$0")/config.sh"
# ─────────────────────────────────────────────────────────────

readonly POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT="$(cd "${POC_DIR}/../.." && pwd)"

# Source shared config for NETBIRD_DOMAIN, ADMIN_*, KEYS_DIR, etc.
# shellcheck source=../../../scripts/config.sh
source "${REPO_ROOT}/scripts/config.sh"

# ── BASTION-SERVER POC CONFIG ────────────────────────────────

# Isolated VM subnet (Docker network: bastion-vms)
BASTION_VM_SUBNET="${BASTION_VM_SUBNET:-10.99.0.0/24}"

# VM static IPs
VM_DB_IPS=("10.99.0.11" "10.99.0.12")
VM_DB_NAMES=("vm-db-1" "vm-db-2")

# MariaDB credentials (match docker-compose.yml)
BASTION_MARIADB_USER="${BASTION_MARIADB_USER:-appuser}"
BASTION_MARIADB_PASSWORD="${BASTION_MARIADB_PASSWORD:-apppass}"
BASTION_MARIADB_DATABASE="${BASTION_MARIADB_DATABASE:-appdb}"
BASTION_MARIADB_PORT="${BASTION_MARIADB_PORT:-3306}"

# NetBird group names for this POC
BASTION_ROUTERS_GROUP="${BASTION_ROUTERS_GROUP:-bastion-routers}"
BASTION_DEVOPS_GROUP="${BASTION_DEVOPS_GROUP:-devops-bastion}"

# Route identifier
BASTION_ROUTE_ID="${BASTION_ROUTE_ID:-bastion-vms}"

# Policy name
BASTION_POLICY_NAME="${BASTION_POLICY_NAME:-devops-to-bastion}"

# Setup key file paths
BASTION_SETUP_KEY_FILE="${KEYS_DIR}/bastion.key"
BASTION_DEVOPS_KEY_FILE="${KEYS_DIR}/devops-bastion.key"

# Container names (match docker-compose.yml)
BASTION_CONTAINER="${BASTION_CONTAINER:-bastion}"
DEVOPS_CONTAINER="${DEVOPS_CONTAINER:-devops-server}"
