#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  test-connectivity.sh
# PURPOSE: Prove end-to-end mesh connectivity by running a REAL SQL
#          round-trip (CREATE / INSERT / SELECT) from the DevOps container
#          to every MariaDB across both clusters, then print a pass/fail
#          matrix. Endpoints are discovered live (not hardcoded).
# USAGE:   ./scripts/test-connectivity.sh
# ─────────────────────────────────────────────────────────────

set -uo pipefail   # NOTE: not -e; we want to tally failures, not abort.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly LIST_SCRIPT="${SCRIPT_DIR}/list-db-endpoints.sh"
readonly TEST_TABLE="mesh_poc_check"
readonly TCP_TIMEOUT_SECONDS="${TCP_TIMEOUT_SECONDS:-8}"

log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

check_prerequisites() {
  command -v docker &>/dev/null || { log_error "docker not found"; exit 1; }
  [[ -x "${LIST_SCRIPT}" ]] || { log_error "Missing ${LIST_SCRIPT}"; exit 1; }
  if ! docker ps --format '{{.Names}}' | grep -qx "${DEVOPS_CONTAINER_NAME}"; then
    log_error "DevOps container '${DEVOPS_CONTAINER_NAME}' is not running (run scripts/devops-up.sh)"
    exit 1
  fi
}

# Run a command inside the DevOps container.
in_devops() { docker exec "${DEVOPS_CONTAINER_NAME}" "$@"; }

# TCP reachability check from inside the container.
check_tcp() {
  local host="$1"
  local port="$2"
  in_devops nc -z -w "${TCP_TIMEOUT_SECONDS}" "${host}" "${port}" &>/dev/null
}

# Real SQL round-trip: create a table, insert a marker row, read it back.
# Echoes the value read back on success; empty on failure.
sql_round_trip() {
  local host="$1"
  local marker="mesh-$(date +%s)-$$"

  in_devops mariadb -h "${host}" -u root -p"${MARIADB_ROOT_PASSWORD}" \
    --connect-timeout=10 "${MARIADB_APP_DB}" -N -B -e "
      CREATE TABLE IF NOT EXISTS ${TEST_TABLE} (
        id INT AUTO_INCREMENT PRIMARY KEY,
        marker VARCHAR(64) NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
      INSERT INTO ${TEST_TABLE} (marker) VALUES ('${marker}');
      SELECT marker FROM ${TEST_TABLE} WHERE marker='${marker}' LIMIT 1;
    " 2>/dev/null | tail -1
}

main() {
  check_prerequisites

  log_info "Discovering MariaDB endpoints across both clusters"
  local endpoints=()
  while IFS= read -r endpoint_line; do
    [[ -n "${endpoint_line}" ]] && endpoints+=("${endpoint_line}")
  done < <("${LIST_SCRIPT}" --plain)
  if [[ ${#endpoints[@]} -eq 0 ]]; then
    log_error "No endpoints discovered"
    exit 1
  fi

  echo
  printf "%-10s %-6s %-16s %-6s %-8s %-8s\n" "CLUSTER" "NS" "CLUSTER-IP" "PORT" "TCP" "SQL"
  printf "%-10s %-6s %-16s %-6s %-8s %-8s\n" "-------" "--" "----------" "----" "---" "---"

  local total=0
  local passed=0
  local failed_targets=()

  for line in "${endpoints[@]}"; do
    # shellcheck disable=SC2206
    local fields=(${line})
    local cluster="${fields[0]}"
    local namespace="${fields[1]}"
    local cluster_ip="${fields[2]}"
    local port="${fields[3]}"
    total=$(( total + 1 ))

    local tcp_result="FAIL"
    local sql_result="FAIL"

    if check_tcp "${cluster_ip}" "${port}"; then
      tcp_result="OK"
      local got
      got="$(sql_round_trip "${cluster_ip}")"
      if [[ -n "${got}" ]]; then
        sql_result="OK"
        passed=$(( passed + 1 ))
      else
        failed_targets+=("${cluster}/${namespace} (SQL)")
      fi
    else
      failed_targets+=("${cluster}/${namespace} (TCP)")
    fi

    printf "%-10s %-6s %-16s %-6s %-8s %-8s\n" \
      "${cluster}" "${namespace}" "${cluster_ip}" "${port}" "${tcp_result}" "${sql_result}"
  done

  echo
  if [[ ${passed} -eq ${total} ]]; then
    log_success "ALL ${passed}/${total} databases reachable with successful SQL round-trip through the mesh"
    exit 0
  fi

  log_error "${passed}/${total} passed. Failures:"
  for target in "${failed_targets[@]}"; do
    log_error "  - ${target}"
  done
  exit 1
}

main "$@"
