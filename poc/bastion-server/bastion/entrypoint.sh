#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  entrypoint.sh (bastion)
# PURPOSE: Start the NetBird agent as a routing peer and enable IP
#          forwarding + masquerade so mesh peers can reach the
#          isolated VM subnet (10.99.0.0/24) through this bastion.
#
# Required env:
#   NB_SETUP_KEY        setup key for the 'bastion-routers' group
#   NB_MANAGEMENT_URL   e.g. https://netbird.local
# Optional env:
#   NB_HOSTNAME         peer name (default: bastion-server)
#   NETBIRD_HOST_IP     host IP for /etc/hosts resolution
#   NETBIRD_DOMAIN      control-plane domain (default: netbird.local)
#   BASTION_VM_SUBNET   subnet to masquerade (default: 10.99.0.0/24)
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
NB_MANAGEMENT_URL="${NB_MANAGEMENT_URL:-https://netbird.local}"
NB_HOSTNAME="${NB_HOSTNAME:-bastion-server}"
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
NETBIRD_HOST_IP="${NETBIRD_HOST_IP:-}"
BASTION_VM_SUBNET="${BASTION_VM_SUBNET:-10.99.0.0/24}"

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

enable_routing() {
  # IP forwarding (also set via docker-compose sysctls, but be explicit)
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  log_info "IP forwarding enabled"

  # Masquerade traffic from the NetBird mesh (100.64.0.0/10) going to the VM subnet.
  # This ensures MariaDB VMs see the bastion's IP as source and don't need a return route.
  iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -d "${BASTION_VM_SUBNET}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -d "${BASTION_VM_SUBNET}" -j MASQUERADE
  log_info "Masquerade rule: 100.64.0.0/10 -> ${BASTION_VM_SUBNET}"
}

start_daemon() {
  log_info "Starting NetBird daemon"
  netbird service install 2>/dev/null || true
  netbird service start 2>/dev/null || true

  # Fallback: run daemon directly if service management is unavailable
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
  enable_routing
  start_daemon
  join_mesh

  log_info "NetBird status:"
  netbird status || true

  log_info "Bastion ready. Routing ${BASTION_VM_SUBNET} via mesh."
  tail -f /dev/null
}

main "$@"
