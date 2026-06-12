#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  entrypoint.sh (devops-server)
# PURPOSE: Start the NetBird daemon, join the mesh, then idle.
#          The operator execs in to run mysql -h commands.
#
# Required env:
#   NB_SETUP_KEY       setup key for the 'devops' group
#   NB_MANAGEMENT_URL  e.g. https://netbird.local
# Optional env:
#   NB_HOSTNAME        peer name (default: devops-bastion-poc)
#   NETBIRD_HOST_IP    host IP for /etc/hosts resolution
#   NETBIRD_DOMAIN     control-plane domain (default: netbird.local)
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-https://netbird.local}"
NB_HOSTNAME="${NB_HOSTNAME:-devops-bastion-poc}"
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
NETBIRD_HOST_IP="${NETBIRD_HOST_IP:-}"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }

add_host_entry() {
  [[ -z "${NETBIRD_HOST_IP}" ]] && return 0
  if ! grep -q "${NETBIRD_DOMAIN}" /etc/hosts; then
    echo "${NETBIRD_HOST_IP} ${NETBIRD_DOMAIN}" >> /etc/hosts
    log_info "Mapped ${NETBIRD_DOMAIN} -> ${NETBIRD_HOST_IP} in /etc/hosts"
  fi
}

start_daemon() {
  log_info "Starting NetBird daemon"
  netbird service install 2>/dev/null || true
  netbird service start 2>/dev/null || true

  if ! pgrep -x netbird >/dev/null 2>&1; then
    nohup netbird service run >/var/log/netbird.log 2>&1 &
    sleep 3
  fi
}

join_mesh() {
  if [[ -z "${NB_SETUP_KEY:-}" ]]; then
    log_error "NB_SETUP_KEY is required"
    exit 1
  fi
  log_info "Joining mesh at ${NB_MANAGEMENT_URL} as ${NB_HOSTNAME}"
  netbird up \
    --management-url "${NB_MANAGEMENT_URL}" \
    --setup-key "${NB_SETUP_KEY}" \
    --hostname "${NB_HOSTNAME}" \
    --foreground-mode=false
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  add_host_entry
  start_daemon
  join_mesh

  log_info "NetBird status:"
  netbird status || true

  log_info "DevOps server ready. Exec in to run: mysql -h 10.99.0.11 -u appuser -papppass"
  tail -f /dev/null
}

main "$@"
