#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  test-connectivity.sh
# PURPOSE: Prove the bastion routing pattern works:
#          Phase 1 — devops-server CAN reach MariaDB VMs via mesh route
#          Phase 2 — disable route → devops-server CANNOT reach VMs
#          Phase 3 — re-enable route → connectivity restores
# USAGE:   ./poc/bastion-server/scripts/test-connectivity.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly CA_CERT="${REPO_ROOT}/netbird/certs/rootCA.pem"
readonly ROUTE_ID_FILE="${KEYS_DIR}/bastion-route.id"
readonly PAT_FILE="${KEYS_DIR}/admin.pat"

MYSQL_CONNECT_TIMEOUT="${MYSQL_CONNECT_TIMEOUT:-10}"
ROUTE_PROPAGATION_WAIT="${ROUTE_PROPAGATION_WAIT:-8}"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; }

check_prerequisites() {
  [[ -f "${PAT_FILE}" ]] || { log_error "PAT not found: ${PAT_FILE}"; exit 1; }
  [[ -f "${ROUTE_ID_FILE}" ]] || { log_error "Route ID not found: ${ROUTE_ID_FILE}"; exit 1; }
  [[ -f "${CA_CERT}" ]] || { log_error "CA cert not found: ${CA_CERT}"; exit 1; }

  if ! docker ps --format '{{.Names}}' | grep -q "^${DEVOPS_CONTAINER}$"; then
    log_error "Container ${DEVOPS_CONTAINER} is not running. Run 'make up' first."
    exit 1
  fi
}

# Test mysql connectivity from devops-server to a VM IP.
# Returns 0 on success, 1 on failure.
test_mysql() {
  local vm_ip="$1"
  docker exec "${DEVOPS_CONTAINER}" \
    mysql -h "${vm_ip}" \
      -u "${BASTION_MARIADB_USER}" \
      -p"${BASTION_MARIADB_PASSWORD}" \
      --connect-timeout="${MYSQL_CONNECT_TIMEOUT}" \
      -e "SELECT 1" >/dev/null 2>&1
}

# Toggle route enabled/disabled via NetBird API.
set_route_enabled() {
  local enabled="$1"  # "true" or "false"
  local route_id pat

  route_id="$(cat "${ROUTE_ID_FILE}")"
  pat="$(cat "${PAT_FILE}")"

  local curl_base=(curl -fsS --cacert "${CA_CERT}" --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1")
  local api="https://${NETBIRD_DOMAIN}/api"

  # Get current route, update enabled field, PUT back
  local route_json
  route_json="$("${curl_base[@]}" -H "Authorization: Token ${pat}" "${api}/routes/${route_id}")"

  local updated_json
  updated_json="$(echo "${route_json}" | jq --argjson e "${enabled}" '{
    description, network_id, enabled: $e, network, metric,
    masquerade, peer_groups, groups, keep_route
  }')"

  "${curl_base[@]}" -H "Authorization: Token ${pat}" \
    -H "Content-Type: application/json" \
    -X PUT "${api}/routes/${route_id}" \
    --data-raw "${updated_json}" >/dev/null

  log_info "Route ${route_id} enabled=${enabled}"
}

# ── TEST PHASES ──────────────────────────────────────────────
phase1_connectivity() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│  Phase 1: Connectivity through bastion route            │"
  echo "└─────────────────────────────────────────────────────────┘"

  local has_failure="false"
  for index in "${!VM_DB_IPS[@]}"; do
    local vm_ip="${VM_DB_IPS[${index}]}"
    local vm_name="${VM_DB_NAMES[${index}]}"
    if test_mysql "${vm_ip}"; then
      pass "mysql -h ${vm_ip} (${vm_name}) — reachable"
    else
      fail "mysql -h ${vm_ip} (${vm_name}) — NOT reachable"
      has_failure="true"
    fi
  done

  [[ "${has_failure}" == "false" ]]
}

phase2_isolation() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│  Phase 2: Isolation (route disabled)                    │"
  echo "└─────────────────────────────────────────────────────────┘"

  log_info "Disabling route..."
  set_route_enabled "false"
  log_info "Waiting ${ROUTE_PROPAGATION_WAIT}s for route withdrawal..."
  sleep "${ROUTE_PROPAGATION_WAIT}"

  local has_failure="false"
  for index in "${!VM_DB_IPS[@]}"; do
    local vm_ip="${VM_DB_IPS[${index}]}"
    local vm_name="${VM_DB_NAMES[${index}]}"
    if test_mysql "${vm_ip}"; then
      fail "mysql -h ${vm_ip} (${vm_name}) — STILL reachable (should be blocked)"
      has_failure="true"
    else
      pass "mysql -h ${vm_ip} (${vm_name}) — unreachable (isolation confirmed)"
    fi
  done

  [[ "${has_failure}" == "false" ]]
}

phase3_restore() {
  echo ""
  echo "┌─────────────────────────────────────────────────────────┐"
  echo "│  Phase 3: Restore (route re-enabled)                    │"
  echo "└─────────────────────────────────────────────────────────┘"

  log_info "Re-enabling route..."
  set_route_enabled "true"
  log_info "Waiting ${ROUTE_PROPAGATION_WAIT}s for route propagation..."
  sleep "${ROUTE_PROPAGATION_WAIT}"

  local has_failure="false"
  for index in "${!VM_DB_IPS[@]}"; do
    local vm_ip="${VM_DB_IPS[${index}]}"
    local vm_name="${VM_DB_NAMES[${index}]}"
    if test_mysql "${vm_ip}"; then
      pass "mysql -h ${vm_ip} (${vm_name}) — reachable again"
    else
      fail "mysql -h ${vm_ip} (${vm_name}) — NOT reachable after restore"
      has_failure="true"
    fi
  done

  [[ "${has_failure}" == "false" ]]
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  check_prerequisites

  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Bastion Server PoC — Connectivity & Isolation Test"
  echo "═══════════════════════════════════════════════════════════"

  local results=()

  if phase1_connectivity; then
    results+=("Phase 1 (connectivity): PASS")
  else
    results+=("Phase 1 (connectivity): FAIL")
  fi

  if phase2_isolation; then
    results+=("Phase 2 (isolation):    PASS")
  else
    results+=("Phase 2 (isolation):    FAIL")
  fi

  if phase3_restore; then
    results+=("Phase 3 (restore):      PASS")
  else
    results+=("Phase 3 (restore):      FAIL")
  fi

  # Summary
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  SUMMARY"
  echo "═══════════════════════════════════════════════════════════"
  for result in "${results[@]}"; do
    echo "  ${result}"
  done
  echo ""

  # Exit non-zero if any phase failed
  for result in "${results[@]}"; do
    if [[ "${result}" == *"FAIL"* ]]; then
      exit 1
    fi
  done
  log_success "All tests passed"
}

main "$@"
