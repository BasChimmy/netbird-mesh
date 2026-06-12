#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  list-db-endpoints.sh
# PURPOSE: Print every MariaDB endpoint (cluster, namespace, ClusterIP,
#          in-cluster DNS, port) across both clusters. Outputs a human
#          table by default, or machine-readable lines with --plain
#          (CLUSTER NAMESPACE CLUSTERIP PORT) for the connectivity test.
# USAGE:   ./scripts/list-db-endpoints.sh [--plain]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/../../scripts/config.sh"

readonly CLIENT_SERVICE="mariadb-client"
OUTPUT_MODE="table"

log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plain) OUTPUT_MODE="plain"; shift ;;
      --help)  echo "Usage: $(basename "$0") [--plain]"; exit 0 ;;
      *)       log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

# Fetch the ClusterIP of the mariadb-client service in one namespace.
get_cluster_ip() {
  local context="$1"
  local namespace="$2"
  kubectl --context "${context}" -n "${namespace}" get svc "${CLIENT_SERVICE}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

emit_endpoint() {
  local context="$1"
  local namespace="$2"
  local cluster_ip
  cluster_ip="$(get_cluster_ip "${context}" "${namespace}")"
  [[ -z "${cluster_ip}" ]] && cluster_ip="<not-found>"

  local dns_name="${CLIENT_SERVICE}.${namespace}.svc.cluster.local"

  if [[ "${OUTPUT_MODE}" == "plain" ]]; then
    echo "${context} ${namespace} ${cluster_ip} ${MARIADB_PORT}"
  else
    printf "%-10s %-8s %-16s %-45s %-5s\n" \
      "${context}" "${namespace}" "${cluster_ip}" "${dns_name}" "${MARIADB_PORT}"
  fi
}

main() {
  parse_args "$@"

  if [[ "${OUTPUT_MODE}" == "table" ]]; then
    printf "%-10s %-8s %-16s %-45s %-5s\n" "CLUSTER" "NS" "CLUSTER-IP" "IN-CLUSTER-DNS" "PORT"
    printf "%-10s %-8s %-16s %-45s %-5s\n" "-------" "--" "----------" "--------------" "----"
  fi

  for namespace in "${CLUSTER_A_NAMESPACES[@]}"; do
    emit_endpoint "${CLUSTER_A_PROFILE}" "${namespace}"
  done
  for namespace in "${CLUSTER_B_NAMESPACES[@]}"; do
    emit_endpoint "${CLUSTER_B_PROFILE}" "${namespace}"
  done
}

main "$@"
