#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  teardown.sh
# PURPOSE: Tear down the entire PoC: DevOps container, both minikube
#          clusters, and the NetBird control plane (with volumes).
#          Optionally also remove generated secrets/keys/certs.
# USAGE:   ./scripts/teardown.sh [--purge] [--yes]
#            --purge  also delete generated certs, keys, and rendered files
#            --yes    skip the confirmation prompt
# ─────────────────────────────────────────────────────────────

set -uo pipefail   # not -e: best-effort cleanup, keep going on errors.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly NETBIRD_DIR_ABS="${SCRIPT_DIR}/../netbird"

PURGE="false"
ASSUME_YES="false"

log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) PURGE="true"; shift ;;
      --yes)   ASSUME_YES="true"; shift ;;
      --help)  echo "Usage: $(basename "$0") [--purge] [--yes]"; exit 0 ;;
      *)       log_warn "Unknown argument: $1"; shift ;;
    esac
  done
}

confirm() {
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  log_warn "This will delete the DevOps container, BOTH minikube clusters,"
  log_warn "and the NetBird control plane (including data volumes)."
  [[ "${PURGE}" == "true" ]] && log_warn "--purge will ALSO delete generated certs/keys."
  read -r -p "Proceed? [y/N] " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || { log_info "Aborted"; exit 0; }
}

remove_devops_container() {
  log_info "Removing DevOps container"
  docker rm -f "${DEVOPS_CONTAINER_NAME}" &>/dev/null || true
}

remove_clusters() {
  for profile in "${CLUSTER_A_PROFILE}" "${CLUSTER_B_PROFILE}"; do
    log_info "Deleting minikube cluster '${profile}'"
    minikube delete --profile "${profile}" &>/dev/null || true
  done
}

remove_control_plane() {
  log_info "Stopping NetBird control plane (with volumes)"
  docker compose -f "${NETBIRD_DIR_ABS}/docker-compose.yml" down -v --remove-orphans &>/dev/null || true

  # Belt-and-suspenders: compose down -v only removes volumes for the current
  # project and only if nothing recreated them. Force-remove the known volumes
  # by name (current 'netbird_*' project + any stale 'netbird-poc_*' orphans
  # from earlier multi-container attempts) so the database is truly wiped and
  # the setup API reopens on the next run.
  local stale_volumes=(
    netbird_netbird_data netbird_caddy_data netbird_caddy_config
    netbird-poc_management-data netbird-poc_signal-data
  )
  for volume in "${stale_volumes[@]}"; do
    docker volume rm -f "${volume}" &>/dev/null || true
  done
}

purge_generated() {
  [[ "${PURGE}" != "true" ]] && return 0
  log_info "Purging generated certs, keys, and rendered manifests"
  rm -f  "${NETBIRD_DIR_ABS}"/certs/*.pem "${NETBIRD_DIR_ABS}"/certs/*.csr \
         "${NETBIRD_DIR_ABS}"/certs/*.srl "${NETBIRD_DIR_ABS}"/certs/*.ext 2>/dev/null || true
  rm -rf "${NETBIRD_DIR_ABS}"/.keys 2>/dev/null || true
  rm -f  "${NETBIRD_DIR_ABS}"/config.yaml "${NETBIRD_DIR_ABS}"/dashboard.env 2>/dev/null || true
  rm -rf "${SCRIPT_DIR}/../k8s/mariadb/.rendered" \
         "${SCRIPT_DIR}/../k8s/netbird-router/.rendered" 2>/dev/null || true
  rm -f  "${SCRIPT_DIR}/../devops-server/rootCA.pem" 2>/dev/null || true
}

main() {
  parse_args "$@"
  confirm
  remove_devops_container
  remove_clusters
  remove_control_plane
  purge_generated
  log_success "Teardown complete"
  [[ "${PURGE}" != "true" ]] && \
    log_info "Generated certs/keys kept. Re-run with --purge to remove them."
  log_info "If you added it, remove the /etc/hosts entry for ${NETBIRD_DOMAIN} manually."
}

main "$@"
