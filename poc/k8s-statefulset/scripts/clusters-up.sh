#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  clusters-up.sh
# PURPOSE: Start two minikube clusters with DISTINCT, non-overlapping
#          service/pod CIDRs so the NetBird mesh can disambiguate routes
#          between them. Idempotent: skips clusters that are already running.
# USAGE:   ./scripts/clusters-up.sh [--down] [--status]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG (sourced from central config.sh) ──────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/../../scripts/config.sh"

ACTION="up"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --down)   ACTION="down";   shift ;;
      --status) ACTION="status"; shift ;;
      --help)   echo "Usage: $(basename "$0") [--down] [--status]"; exit 0 ;;
      *)        log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  local required_tools=("minikube" "kubectl")
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
}

is_cluster_running() {
  local profile="$1"
  minikube status -p "${profile}" --format '{{.Host}}' 2>/dev/null | grep -q "Running"
}

# Start a single cluster with its own service + pod CIDR.
start_cluster() {
  local profile="$1"
  local service_cidr="$2"
  local pod_cidr="$3"

  if is_cluster_running "${profile}"; then
    log_success "Cluster '${profile}' already running"
    return 0
  fi

  log_info "Starting cluster '${profile}' (service ${service_cidr}, pod ${pod_cidr})"
  minikube start \
    --profile "${profile}" \
    --driver "${MINIKUBE_DRIVER}" \
    --cpus "${MINIKUBE_CPUS}" \
    --memory "${MINIKUBE_MEMORY_MB}" \
    --kubernetes-version "${MINIKUBE_K8S_VERSION}" \
    --service-cluster-ip-range "${service_cidr}" \
    --extra-config "kubeadm.pod-network-cidr=${pod_cidr}"

  log_success "Cluster '${profile}' started"
}

stop_cluster() {
  local profile="$1"
  if ! minikube profile list 2>/dev/null | grep -q "${profile}"; then
    log_info "Cluster '${profile}' does not exist, nothing to delete"
    return 0
  fi
  log_info "Deleting cluster '${profile}'"
  minikube delete --profile "${profile}"
  log_success "Cluster '${profile}' deleted"
}

verify_cluster() {
  local profile="$1"
  local expected_cidr="$2"

  log_info "Verifying cluster '${profile}'"
  if ! kubectl --context "${profile}" get nodes &>/dev/null; then
    log_error "Cannot reach cluster '${profile}'"
    return 1
  fi
  kubectl --context "${profile}" get nodes -o wide

  # Confirm the configured service CIDR actually took effect.
  local actual_cidr
  actual_cidr="$(kubectl --context "${profile}" cluster-info dump 2>/dev/null \
    | grep -m1 -- '--service-cluster-ip-range' | sed 's/.*=//; s/[",]//g' | tr -d ' ' || true)"
  if [[ -n "${actual_cidr}" ]]; then
    if [[ "${actual_cidr}" == "${expected_cidr}" ]]; then
      log_success "Cluster '${profile}' service CIDR = ${actual_cidr}"
    else
      log_warn "Cluster '${profile}' service CIDR is ${actual_cidr}, expected ${expected_cidr}"
    fi
  fi
}

run_up() {
  start_cluster "${CLUSTER_A_PROFILE}" "${CLUSTER_A_SERVICE_CIDR}" "${CLUSTER_A_POD_CIDR}"
  start_cluster "${CLUSTER_B_PROFILE}" "${CLUSTER_B_SERVICE_CIDR}" "${CLUSTER_B_POD_CIDR}"

  verify_cluster "${CLUSTER_A_PROFILE}" "${CLUSTER_A_SERVICE_CIDR}"
  verify_cluster "${CLUSTER_B_PROFILE}" "${CLUSTER_B_SERVICE_CIDR}"

  # Sanity guard: the whole routing model breaks if CIDRs overlap.
  if [[ "${CLUSTER_A_SERVICE_CIDR}" == "${CLUSTER_B_SERVICE_CIDR}" ]]; then
    log_error "Cluster service CIDRs must NOT be identical: ${CLUSTER_A_SERVICE_CIDR}"
    exit 1
  fi

  log_success "Both clusters up. Contexts: ${CLUSTER_A_PROFILE}, ${CLUSTER_B_PROFILE}"
}

run_down() {
  stop_cluster "${CLUSTER_A_PROFILE}"
  stop_cluster "${CLUSTER_B_PROFILE}"
}

run_status() {
  for profile in "${CLUSTER_A_PROFILE}" "${CLUSTER_B_PROFILE}"; do
    echo "── ${profile} ──"
    minikube status -p "${profile}" 2>/dev/null || log_warn "'${profile}' not found"
  done
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_prerequisites

  case "${ACTION}" in
    up)     run_up ;;
    down)   run_down ;;
    status) run_status ;;
  esac
}

main "$@"
