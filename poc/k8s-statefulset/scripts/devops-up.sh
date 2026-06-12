#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  devops-up.sh
# PURPOSE: Build the DevOps server image (staging the local CA into the
#          build context) and run it as a NetBird mesh peer in the
#          'devops' group. Connects to the host control plane.
# USAGE:   ./scripts/devops-up.sh [--build-only] [--down]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/../../scripts/config.sh"

readonly DEVOPS_DIR="${SCRIPT_DIR}/../devops-server"
readonly CA_CERT="${SCRIPT_DIR}/../../netbird/certs/rootCA.pem"
readonly DEVOPS_KEY_FILE="${KEYS_DIR}/devops.key"

ACTION="up"

log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build-only) ACTION="build"; shift ;;
      --down)       ACTION="down";  shift ;;
      --help)       echo "Usage: $(basename "$0") [--build-only] [--down]"; exit 0 ;;
      *)            log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  command -v docker &>/dev/null || { log_error "docker not found"; exit 1; }
  [[ -f "${CA_CERT}" ]] || { log_error "CA cert missing: ${CA_CERT}"; exit 1; }
}

build_image() {
  log_info "Staging CA into build context"
  cp "${CA_CERT}" "${DEVOPS_DIR}/rootCA.pem"

  log_info "Building ${DEVOPS_IMAGE}"
  docker build -t "${DEVOPS_IMAGE}" "${DEVOPS_DIR}"

  # Don't leave the cert lying in the build context.
  rm -f "${DEVOPS_DIR}/rootCA.pem"
  log_success "Image built: ${DEVOPS_IMAGE}"
}

run_container() {
  [[ -f "${DEVOPS_KEY_FILE}" ]] || {
    log_error "DevOps setup key missing: ${DEVOPS_KEY_FILE} (run netbird-bootstrap.sh)"; exit 1; }
  local setup_key
  setup_key="$(cat "${DEVOPS_KEY_FILE}")"

  # Auto-detect (or honour explicit) host IP. The DevOps container shares the
  # host's Docker VM, so cluster A's host.minikube.internal value applies.
  local host_ip
  host_ip="$(resolve_host_ip "${CLUSTER_A_PROFILE}")"
  log_info "Using host IP ${host_ip} for control-plane resolution"

  # Remove any prior instance.
  docker rm -f "${DEVOPS_CONTAINER_NAME}" &>/dev/null || true

  log_info "Starting ${DEVOPS_CONTAINER_NAME} (NetBird peer in '${NETBIRD_DEVOPS_GROUP}' group)"
  docker run -d \
    --name "${DEVOPS_CONTAINER_NAME}" \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --add-host "${NETBIRD_DOMAIN}:${host_ip}" \
    -e NB_SETUP_KEY="${setup_key}" \
    -e NB_MANAGEMENT_URL="${NETBIRD_MGMT_URL}" \
    -e NB_HOSTNAME="${DEVOPS_CONTAINER_NAME}" \
    -e NETBIRD_DOMAIN="${NETBIRD_DOMAIN}" \
    "${DEVOPS_IMAGE}"

  log_success "Container started. Follow logs: docker logs -f ${DEVOPS_CONTAINER_NAME}"
}

stop_container() {
  log_info "Removing ${DEVOPS_CONTAINER_NAME}"
  docker rm -f "${DEVOPS_CONTAINER_NAME}" &>/dev/null || true
  log_success "Removed"
}

main() {
  parse_args "$@"
  check_prerequisites

  case "${ACTION}" in
    build) build_image ;;
    down)  stop_container ;;
    up)    build_image; run_container ;;
  esac
}

main "$@"
