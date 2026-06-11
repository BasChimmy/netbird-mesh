#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  deploy-router.sh
# PURPOSE: Render and deploy a NetBird routing peer into one cluster.
#          Injects that cluster's setup key, a unique peer hostname, the
#          self-signed CA, and the host IP for control-plane resolution.
# USAGE:   ./scripts/deploy-router.sh --cluster A|B
#          ./scripts/deploy-router.sh --cluster A --dry-run
# ─────────────────────────────────────────────────────────────

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly TEMPLATE="${SCRIPT_DIR}/../k8s/netbird-router/router.yaml.tmpl"
readonly RENDER_DIR="${SCRIPT_DIR}/../k8s/netbird-router/.rendered"
readonly CA_CERT="${SCRIPT_DIR}/../netbird/certs/rootCA.pem"

CLUSTER=""
DRY_RUN="${DRY_RUN:-false}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster) CLUSTER="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --help)    echo "Usage: $(basename "$0") --cluster A|B [--dry-run]"; exit 0 ;;
      *)         log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  for tool in kubectl; do
    command -v "${tool}" &>/dev/null || { log_error "Missing tool: ${tool}"; exit 1; }
  done
  [[ -f "${TEMPLATE}" ]] || { log_error "Template missing: ${TEMPLATE}"; exit 1; }
  [[ -f "${CA_CERT}" ]]  || { log_error "CA cert missing: ${CA_CERT}"; exit 1; }
}

# Map --cluster A|B to its context, setup key file, and peer hostname.
resolve_cluster_vars() {
  case "${CLUSTER}" in
    A|a)
      KUBE_CONTEXT="${CLUSTER_A_PROFILE}"
      SETUP_KEY_FILE="${KEYS_DIR}/router-a.key"
      PEER_HOSTNAME="netbird-router-clustera" ;;
    B|b)
      KUBE_CONTEXT="${CLUSTER_B_PROFILE}"
      SETUP_KEY_FILE="${KEYS_DIR}/router-b.key"
      PEER_HOSTNAME="netbird-router-clusterb" ;;
    *)
      log_error "Invalid --cluster '${CLUSTER}' (use A or B)"; exit 1 ;;
  esac

  [[ -f "${SETUP_KEY_FILE}" ]] || {
    log_error "Setup key not found: ${SETUP_KEY_FILE} (run netbird-bootstrap.sh first)"; exit 1; }
  SETUP_KEY="$(cat "${SETUP_KEY_FILE}")"

  # Auto-detect (or honour explicit) host IP for THIS cluster's pods.
  HOST_IP="$(resolve_host_ip "${KUBE_CONTEXT}")"
  log_info "Using host IP ${HOST_IP} for control-plane resolution (cluster ${CLUSTER})"
}

render_manifest() {
  mkdir -p "${RENDER_DIR}"
  local out_file="${RENDER_DIR}/router-${CLUSTER}.yaml"

  sed \
    -e "s|__SETUP_KEY__|${SETUP_KEY}|g" \
    -e "s|__HOST_IP__|${HOST_IP}|g" \
    -e "s|__NETBIRD_DOMAIN__|${NETBIRD_DOMAIN}|g" \
    -e "s|__PEER_HOSTNAME__|${PEER_HOSTNAME}|g" \
    "${TEMPLATE}" > "${out_file}"

  echo "${out_file}"
}

# Create the netbird namespace and the CA ConfigMap (idempotent) so the
# agent can trust the self-signed management TLS. Done outside the rendered
# manifest to avoid embedding the multi-line cert in YAML.
ensure_namespace_and_ca() {
  kubectl --context "${KUBE_CONTEXT}" create namespace netbird \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
  kubectl --context "${KUBE_CONTEXT}" -n netbird create configmap netbird-ca \
    --from-file=rootCA.pem="${CA_CERT}" \
    --dry-run=client -o yaml | kubectl --context "${KUBE_CONTEXT}" apply -f - >/dev/null
}

deploy() {
  local manifest
  manifest="$(render_manifest)"
  log_info "Deploying NetBird router to context='${KUBE_CONTEXT}' (cluster ${CLUSTER})"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "DRY RUN — manifest rendered at ${manifest}, not applied"
    return 0
  fi

  ensure_namespace_and_ca
  kubectl --context "${KUBE_CONTEXT}" apply -f "${manifest}"

  log_info "Waiting for router rollout (timeout ${ROLLOUT_TIMEOUT})"
  if ! kubectl --context "${KUBE_CONTEXT}" -n netbird rollout status \
      deployment/netbird-router --timeout "${ROLLOUT_TIMEOUT}"; then
    log_error "Router rollout failed; recent logs:"
    kubectl --context "${KUBE_CONTEXT}" -n netbird logs -l app=netbird-router --tail=30 || true
    return 1
  fi
  log_success "NetBird router ready in cluster ${CLUSTER}"
}

main() {
  parse_args "$@"
  check_prerequisites
  resolve_cluster_vars
  deploy
}

main "$@"
