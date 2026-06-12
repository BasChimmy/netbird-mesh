#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  up.sh
# PURPOSE: Bring up the entire bastion-server PoC end-to-end:
#          1. Verify shared NetBird management is running
#          2. Run bootstrap (groups + keys)
#          3. Copy CA cert into build contexts
#          4. docker compose up
#          5. Run bootstrap --routes (after bastion registers)
#          6. Wait for mesh connectivity
# USAGE:   ./poc/bastion-server/scripts/up.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly CA_CERT="${REPO_ROOT}/netbird/certs/rootCA.pem"
readonly COMPOSE_FILE="${POC_DIR}/docker-compose.yml"
PEER_WAIT_TIMEOUT="${PEER_WAIT_TIMEOUT:-60}"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

check_prerequisites() {
  local required_tools=("docker" "curl" "jq")
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
}

verify_netbird_running() {
  log_info "Checking shared NetBird management plane..."
  if ! curl -fsS --cacert "${CA_CERT}" \
      --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1" \
      "https://${NETBIRD_DOMAIN}/api/users" \
      -H "Authorization: Token $(cat "${KEYS_DIR}/admin.pat")" >/dev/null 2>&1; then
    log_error "NetBird management plane not reachable. Run 'make netbird-up' from repo root first."
    exit 1
  fi
  log_success "NetBird management plane is running"
}

stage_ca_certs() {
  log_info "Copying CA cert into build contexts"
  cp "${CA_CERT}" "${POC_DIR}/bastion/rootCA.pem"
  cp "${CA_CERT}" "${POC_DIR}/devops-server/rootCA.pem"
}

run_bootstrap() {
  log_info "Running bootstrap (groups + setup keys)"
  "${SCRIPT_DIR}/bootstrap.sh"
}

compose_up() {
  log_info "Starting docker compose stack"
  local bastion_key devops_key

  bastion_key="$(cat "${BASTION_SETUP_KEY_FILE}")"
  devops_key="$(cat "${BASTION_DEVOPS_KEY_FILE}")"

  # Detect host IP for containers to resolve netbird.local
  local host_ip
  host_ip="${NETBIRD_HOST_IP:-}"
  if [[ -z "${host_ip}" ]]; then
    # Docker Desktop / Rancher Desktop expose host as host-gateway
    host_ip="host-gateway"
  fi

  NB_BASTION_SETUP_KEY="${bastion_key}" \
  NB_DEVOPS_SETUP_KEY="${devops_key}" \
  NETBIRD_HOST_IP="${host_ip}" \
    docker compose -f "${COMPOSE_FILE}" up -d --build
}

wait_for_peer() {
  local container="$1"
  local timeout="${PEER_WAIT_TIMEOUT}"
  local elapsed=0

  log_info "Waiting for ${container} to join the mesh (timeout ${timeout}s)..."
  while [[ ${elapsed} -lt ${timeout} ]]; do
    if docker exec "${container}" netbird status 2>/dev/null | grep -q "Connected"; then
      log_success "${container} connected to mesh"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  log_warn "${container} did not connect within ${timeout}s (may still be connecting)"
}

run_routes_bootstrap() {
  log_info "Running bootstrap --routes (route + ACL policy)"
  "${SCRIPT_DIR}/bootstrap.sh" --routes
}

print_summary() {
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Bastion Server PoC — UP"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "  VM Database 1:  10.99.0.11 (vm-db-1)"
  echo "  VM Database 2:  10.99.0.12 (vm-db-2)"
  echo "  Bastion:        10.99.0.10 (routing peer)"
  echo "  DevOps Server:  netbird-only network"
  echo ""
  echo "  Test connectivity:"
  echo "    make test"
  echo "  Or manually:"
  echo "    docker exec devops-server mysql -h 10.99.0.11 -u appuser -papppass -e 'SELECT 1'"
  echo ""
  echo "═══════════════════════════════════════════════════════════"
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  check_prerequisites
  verify_netbird_running
  run_bootstrap
  stage_ca_certs
  compose_up
  wait_for_peer "${BASTION_CONTAINER}"
  wait_for_peer "${DEVOPS_CONTAINER}"
  run_routes_bootstrap
  print_summary
}

main "$@"
