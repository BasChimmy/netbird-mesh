#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  teardown.sh
# PURPOSE: Tear down the bastion-server PoC containers and networks.
#          Optionally cleans up NetBird API resources (--purge).
# USAGE:   ./poc/bastion-server/scripts/teardown.sh [--purge]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly CA_CERT="${REPO_ROOT}/netbird/certs/rootCA.pem"
readonly COMPOSE_FILE="${POC_DIR}/docker-compose.yml"

DO_PURGE="false"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) DO_PURGE="true"; shift ;;
      --help)  echo "Usage: $(basename "$0") [--purge]"; exit 0 ;;
      *)       shift ;;
    esac
  done
}

compose_down() {
  log_info "Stopping bastion-server PoC containers"
  docker compose -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
  log_success "Containers stopped"
}

cleanup_build_artifacts() {
  rm -f "${POC_DIR}/bastion/rootCA.pem"
  rm -f "${POC_DIR}/devops-server/rootCA.pem"
}

purge_netbird_resources() {
  local pat_file="${KEYS_DIR}/admin.pat"
  [[ -f "${pat_file}" ]] || { log_warn "No PAT found, skipping API cleanup"; return 0; }
  [[ -f "${CA_CERT}" ]] || { log_warn "No CA cert, skipping API cleanup"; return 0; }

  local pat
  pat="$(cat "${pat_file}")"
  local curl_base=(curl -fsS --cacert "${CA_CERT}" --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1")
  local api="https://${NETBIRD_DOMAIN}/api"

  log_info "Purging NetBird API resources for bastion PoC"

  # Delete route
  local route_id
  route_id="$("${curl_base[@]}" -H "Authorization: Token ${pat}" "${api}/routes" \
    | jq -r --arg nid "${BASTION_ROUTE_ID}" '.[] | select(.network_id==$nid) | .id' | head -1)"
  if [[ -n "${route_id}" ]]; then
    "${curl_base[@]}" -H "Authorization: Token ${pat}" -X DELETE "${api}/routes/${route_id}" || true
    log_info "Deleted route ${BASTION_ROUTE_ID}"
  fi

  # Delete policy
  local policy_id
  policy_id="$("${curl_base[@]}" -H "Authorization: Token ${pat}" "${api}/policies" \
    | jq -r --arg n "${BASTION_POLICY_NAME}" '.[] | select(.name==$n) | .id' | head -1)"
  if [[ -n "${policy_id}" ]]; then
    "${curl_base[@]}" -H "Authorization: Token ${pat}" -X DELETE "${api}/policies/${policy_id}" || true
    log_info "Deleted policy ${BASTION_POLICY_NAME}"
  fi

  # Remove setup key files
  rm -f "${BASTION_SETUP_KEY_FILE}" "${BASTION_DEVOPS_KEY_FILE}"
  rm -f "${KEYS_DIR}/bastion-bootstrap.state" "${KEYS_DIR}/bastion-route.id"
  log_success "NetBird resources purged"
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  compose_down
  cleanup_build_artifacts
  if [[ "${DO_PURGE}" == "true" ]]; then
    purge_netbird_resources
  fi
  log_success "Bastion-server PoC torn down"
}

main "$@"
