#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# FILE:    config.sh
# PURPOSE: Single source of truth for all PoC parameters. Sourced by
#          every other script. Every value can be overridden via env var.
# USAGE:   source "$(dirname "$0")/config.sh"
# ─────────────────────────────────────────────────────────────

# ── NETBIRD CONTROL PLANE ────────────────────────────────────
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
NETBIRD_DASHBOARD_URL="${NETBIRD_DASHBOARD_URL:-https://${NETBIRD_DOMAIN}}"
NETBIRD_MGMT_URL="${NETBIRD_MGMT_URL:-https://${NETBIRD_DOMAIN}}"
NETBIRD_DIR="${NETBIRD_DIR:-netbird}"
NETBIRD_CA_DIR="${NETBIRD_CA_DIR:-${NETBIRD_DIR}/certs}"
NETBIRD_CA_CERT="${NETBIRD_CA_CERT:-${NETBIRD_CA_DIR}/rootCA.pem}"

# ── MINIKUBE CLUSTERS ────────────────────────────────────────
# Distinct, non-overlapping service CIDRs are MANDATORY so the mesh can
# disambiguate routes between the two clusters.
CLUSTER_A_PROFILE="${CLUSTER_A_PROFILE:-clusterA}"
CLUSTER_B_PROFILE="${CLUSTER_B_PROFILE:-clusterB}"
CLUSTER_A_SERVICE_CIDR="${CLUSTER_A_SERVICE_CIDR:-10.96.0.0/16}"
CLUSTER_B_SERVICE_CIDR="${CLUSTER_B_SERVICE_CIDR:-10.97.0.0/16}"
CLUSTER_A_POD_CIDR="${CLUSTER_A_POD_CIDR:-10.244.0.0/16}"
CLUSTER_B_POD_CIDR="${CLUSTER_B_POD_CIDR:-10.245.0.0/16}"

# Per-cluster resource sizing. Kept modest because the host also runs the
# NetBird control plane and the DevOps container.
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
MINIKUBE_MEMORY_MB="${MINIKUBE_MEMORY_MB:-3072}"
MINIKUBE_K8S_VERSION="${MINIKUBE_K8S_VERSION:-stable}"

# ── NAMESPACE -> CLUSTER MAPPING ─────────────────────────────
# Cluster A hosts the first three namespaces, cluster B the last two.
CLUSTER_A_NAMESPACES=("ns1" "ns2" "ns3")
CLUSTER_B_NAMESPACES=("ns4" "ns5")

# ── MARIADB ──────────────────────────────────────────────────
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-rootpass}"
MARIADB_APP_DB="${MARIADB_APP_DB:-appdb}"
MARIADB_APP_USER="${MARIADB_APP_USER:-appuser}"
MARIADB_APP_PASSWORD="${MARIADB_APP_PASSWORD:-apppass}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_STORAGE_SIZE="${MARIADB_STORAGE_SIZE:-1Gi}"

# ── NETBIRD GROUPS / ROUTING ─────────────────────────────────
# Each cluster's routing peer lives in its OWN group so each route maps
# to exactly one cluster. A shared group would make both routers try to
# advertise both CIDRs and blackhole cross-cluster traffic.
NETBIRD_ROUTERS_GROUP_A="${NETBIRD_ROUTERS_GROUP_A:-kubernetes-routers-a}"
NETBIRD_ROUTERS_GROUP_B="${NETBIRD_ROUTERS_GROUP_B:-kubernetes-routers-b}"
NETBIRD_DEVOPS_GROUP="${NETBIRD_DEVOPS_GROUP:-devops}"

# Route identifiers (group HA routes; one per cluster here).
NETBIRD_ROUTE_ID_A="${NETBIRD_ROUTE_ID_A:-clusterA-svc}"
NETBIRD_ROUTE_ID_B="${NETBIRD_ROUTE_ID_B:-clusterB-svc}"

# ── CONTROL-PLANE BOOTSTRAP (setup API) ──────────────────────
# Host IP that minikube pods use to reach the host control plane.
# (minikube exposes the host as host.minikube.internal -> this IP.)
#
# Leave EMPTY to auto-detect per machine via resolve_host_ip() below — the
# correct value differs across Docker backends (Rancher Desktop, Docker
# Desktop, Colima, Linux). Set it explicitly to override auto-detection:
#   NETBIRD_HOST_IP=192.168.65.254 make routers
NETBIRD_HOST_IP="${NETBIRD_HOST_IP:-}"
# Fallback used only if auto-detection fails (common Docker/Rancher Desktop value).
NETBIRD_HOST_IP_FALLBACK="${NETBIRD_HOST_IP_FALLBACK:-192.168.65.254}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@netbird.local}"
ADMIN_NAME="${ADMIN_NAME:-PoC Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-NetBirdAdmin1!}"

# Resolve the host IP that cluster pods use to reach the host control plane.
# Order of precedence:
#   1. explicit NETBIRD_HOST_IP env var (honoured as-is)
#   2. auto-detect from the given minikube profile's host.minikube.internal
#   3. NETBIRD_HOST_IP_FALLBACK
# Usage: resolve_host_ip <minikube-profile>   # echoes the IP
resolve_host_ip() {
  local profile="${1:-}"

  if [[ -n "${NETBIRD_HOST_IP}" ]]; then
    echo "${NETBIRD_HOST_IP}"
    return 0
  fi

  local detected=""
  if [[ -n "${profile}" ]] && command -v minikube &>/dev/null; then
    detected="$(minikube -p "${profile}" ssh \
      "grep host.minikube.internal /etc/hosts 2>/dev/null | awk '{print \$1}'" 2>/dev/null \
      | tr -d '\r' | tr -d '[:space:]')"
  fi

  # Only accept a well-formed IPv4 address; minikube can print error text to
  # stdout (e.g. "profile not found"), which must never be treated as an IP.
  if [[ "${detected}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "${detected}"
  else
    echo "${NETBIRD_HOST_IP_FALLBACK}"
  fi
}

# Setup keys (filled in by the bootstrap from the API). Scripts read
# these from env or from netbird/.keys/*.key files written during setup.
KEYS_DIR="${KEYS_DIR:-${NETBIRD_DIR}/.keys}"
ROUTER_SETUP_KEY_A="${ROUTER_SETUP_KEY_A:-}"
ROUTER_SETUP_KEY_B="${ROUTER_SETUP_KEY_B:-}"
DEVOPS_SETUP_KEY="${DEVOPS_SETUP_KEY:-}"

# ── DEVOPS SERVER CONTAINER ──────────────────────────────────
DEVOPS_IMAGE="${DEVOPS_IMAGE:-netbird-poc/devops-server:latest}"
DEVOPS_CONTAINER_NAME="${DEVOPS_CONTAINER_NAME:-devops-server}"
