#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# entrypoint.sh — start the NetBird daemon and join the mesh, then idle.
#
# Required env:
#   NB_SETUP_KEY       reusable setup key for the 'devops' group
#   NB_MANAGEMENT_URL  e.g. https://netbird.local
# Optional env:
#   NB_HOSTNAME        peer name in the dashboard (default devops-server)
#   NETBIRD_HOST_IP    host IP to map NETBIRD_DOMAIN to (for /etc/hosts)
#   NETBIRD_DOMAIN     control-plane domain (default netbird.local)
# ─────────────────────────────────────────────────────────────

set -euo pipefail

NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-https://netbird.local}"
NB_HOSTNAME="${NB_HOSTNAME:-devops-server}"
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
NETBIRD_HOST_IP="${NETBIRD_HOST_IP:-}"

log_info()  { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }

# Map the control-plane domain to the host IP if provided (mirrors the
# routers' hostAliases). Lets the container resolve netbird.local.
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
  # Run the daemon in the background (no systemd in the container).
  netbird service start 2>/dev/null || netbird up --help >/dev/null 2>&1 || true
  # Fallback: start the management daemon directly.
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

main() {
  add_host_entry
  start_daemon
  join_mesh

  log_info "NetBird status:"
  netbird status || true

  log_info "DevOps server ready. Idling; exec in to run the connectivity test."
  # Keep the container alive.
  tail -f /dev/null
}

main "$@"
