#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  deploy-mariadb.sh
# PURPOSE: Render the MariaDB StatefulSet template for one or more
#          namespaces and deploy them into a given cluster context.
# USAGE:   ./scripts/deploy-mariadb.sh --context <ctx> --namespaces "ns1 ns2"
#          ./scripts/deploy-mariadb.sh           # deploys the full PoC layout
#          ./scripts/deploy-mariadb.sh --dry-run
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG (sourced from central config.sh) ──────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/../../scripts/config.sh"

readonly TEMPLATE="${SCRIPT_DIR}/../k8s/mariadb/mariadb.yaml.tmpl"
readonly RENDER_DIR="${SCRIPT_DIR}/../k8s/mariadb/.rendered"

# Optional overrides; empty means "deploy the full PoC layout".
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
TARGET_NAMESPACES=()
DRY_RUN="${DRY_RUN:-false}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }
log_dryrun()  { echo "[DRY]   $(date '+%H:%M:%S') $*"; }

run_command() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dryrun "Would run: $*"
  else
    "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)    KUBE_CONTEXT="$2"; shift 2 ;;
      --namespaces) read -r -a TARGET_NAMESPACES <<< "$2"; shift 2 ;;
      --dry-run)    DRY_RUN="true"; shift ;;
      --help)
        echo "Usage: $(basename "$0") [--context CTX --namespaces \"ns1 ns2\"] [--dry-run]"
        exit 0 ;;
      *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  if ! command -v kubectl &>/dev/null; then
    log_error "Required tool not found: kubectl"
    exit 1
  fi
  if [[ ! -f "${TEMPLATE}" ]]; then
    log_error "Template not found: ${TEMPLATE}"
    exit 1
  fi
}

# Render the template for one namespace and echo the rendered file path.
render_manifest() {
  local namespace="$1"
  local out_file="${RENDER_DIR}/mariadb-${namespace}.yaml"
  mkdir -p "${RENDER_DIR}"

  sed \
    -e "s|__NAMESPACE__|${namespace}|g" \
    -e "s|__ROOT_PASSWORD__|${MARIADB_ROOT_PASSWORD}|g" \
    -e "s|__APP_DB__|${MARIADB_APP_DB}|g" \
    -e "s|__APP_USER__|${MARIADB_APP_USER}|g" \
    -e "s|__APP_PASSWORD__|${MARIADB_APP_PASSWORD}|g" \
    -e "s|__MARIADB_IMAGE__|${MARIADB_IMAGE}|g" \
    -e "s|__MARIADB_PORT__|${MARIADB_PORT}|g" \
    -e "s|__STORAGE_SIZE__|${MARIADB_STORAGE_SIZE}|g" \
    "${TEMPLATE}" > "${out_file}"

  echo "${out_file}"
}

deploy_namespace() {
  local context="$1"
  local namespace="$2"

  log_info "Deploying MariaDB to context='${context}' namespace='${namespace}'"
  run_command kubectl --context "${context}" create namespace "${namespace}" \
    --dry-run=client -o yaml \
    | { [[ "${DRY_RUN}" == "true" ]] && cat >/dev/null || kubectl --context "${context}" apply -f - ; }

  local manifest
  manifest="$(render_manifest "${namespace}")"
  run_command kubectl --context "${context}" apply -f "${manifest}"
}

wait_for_namespace() {
  local context="$1"
  local namespace="$2"
  [[ "${DRY_RUN}" == "true" ]] && return 0

  log_info "Waiting for mariadb-0 rollout in '${namespace}' (timeout ${ROLLOUT_TIMEOUT})"
  if ! kubectl --context "${context}" -n "${namespace}" rollout status \
      statefulset/mariadb --timeout "${ROLLOUT_TIMEOUT}"; then
    log_error "MariaDB rollout failed in '${namespace}'"
    return 1
  fi
  log_success "MariaDB ready in '${namespace}'"
}

# Deploy a space-separated set of namespaces into one context.
deploy_set() {
  local context="$1"; shift
  local namespaces=("$@")
  local failed_namespaces=()

  for namespace in "${namespaces[@]}"; do
    if deploy_namespace "${context}" "${namespace}" \
        && wait_for_namespace "${context}" "${namespace}"; then
      log_success "Done: ${context}/${namespace}"
    else
      log_error "Failed: ${context}/${namespace}"
      failed_namespaces+=("${context}/${namespace}")
    fi
  done

  if [[ ${#failed_namespaces[@]} -gt 0 ]]; then
    log_error "Failed namespaces: ${failed_namespaces[*]}"
    return 1
  fi
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_prerequisites

  [[ "${DRY_RUN}" == "true" ]] && log_warn "DRY RUN MODE — no changes will be made"

  # Explicit single-target mode (used for the Task 4 single-namespace test).
  if [[ -n "${KUBE_CONTEXT}" && ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
    deploy_set "${KUBE_CONTEXT}" "${TARGET_NAMESPACES[@]}"
    log_success "MariaDB deployment complete"
    exit 0
  fi

  # Full PoC layout: ns1-3 on clusterA, ns4-5 on clusterB.
  deploy_set "${CLUSTER_A_PROFILE}" "${CLUSTER_A_NAMESPACES[@]}"
  deploy_set "${CLUSTER_B_PROFILE}" "${CLUSTER_B_NAMESPACES[@]}"
  log_success "MariaDB deployed across all namespaces"
}

main "$@"
