#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  bootstrap.sh
# PURPOSE: Create NetBird groups, setup keys, route, and ACL policy
#          for the bastion-server PoC. Idempotent — safe to run twice.
#
# Requires the shared NetBird management plane to be running and
# the admin PAT to exist (from netbird/netbird-bootstrap.sh base run).
#
# USAGE:   ./poc/bastion-server/scripts/bootstrap.sh
#          ./poc/bastion-server/scripts/bootstrap.sh --routes
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

readonly CA_CERT="${REPO_ROOT}/netbird/certs/rootCA.pem"
readonly PAT_FILE="${KEYS_DIR}/admin.pat"
readonly STATE_FILE="${KEYS_DIR}/bastion-bootstrap.state"

CURL_BASE=(curl -fsS --cacert "${CA_CERT}" --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1")
API="https://${NETBIRD_DOMAIN}/api"

DO_ROUTES="${DO_ROUTES:-false}"

readonly SETUP_KEY_EXPIRY_SECONDS=31536000

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --routes) DO_ROUTES="true"; shift ;;
      --help)   echo "Usage: $(basename "$0") [--routes]"; exit 0 ;;
      *)        log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  local required_tools=("curl" "jq")
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
  [[ -f "${CA_CERT}" ]] || { log_error "CA cert missing: ${CA_CERT} (run netbird-up.sh first)"; exit 1; }
  [[ -f "${PAT_FILE}" ]] || { log_error "PAT not found: ${PAT_FILE} (run netbird/netbird-bootstrap.sh first)"; exit 1; }
  mkdir -p "${KEYS_DIR}"
}

# Authenticated API helpers
api_get() {
  "${CURL_BASE[@]}" -H "Authorization: Token ${PAT}" "${API}$1"
}
api_post() {
  "${CURL_BASE[@]}" -H "Authorization: Token ${PAT}" \
    -H "Content-Type: application/json" -X POST "${API}$1" --data-raw "$2"
}
api_put() {
  "${CURL_BASE[@]}" -H "Authorization: Token ${PAT}" \
    -H "Content-Type: application/json" -X PUT "${API}$1" --data-raw "$2"
}

# Return group ID for a name, creating if absent.
ensure_group() {
  local group_name="$1"
  local existing_id
  existing_id="$(api_get "/groups" | jq -r --arg n "${group_name}" \
    '.[] | select(.name==$n) | .id' | head -1)"
  if [[ -n "${existing_id}" ]]; then
    echo "${existing_id}"
    return 0
  fi
  api_post "/groups" "{\"name\":\"${group_name}\"}" | jq -r '.id'
}

# Create a reusable+ephemeral setup key; write to file.
ensure_setup_key() {
  local key_name="$1"
  local group_id="$2"
  local out_file="$3"

  if [[ -f "${out_file}" ]]; then
    log_info "Reusing setup key ${key_name} (${out_file})"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "${key_name}" \
    --argjson expires "${SETUP_KEY_EXPIRY_SECONDS}" \
    --arg gid "${group_id}" \
    '{name:$name, type:"reusable", expires_in:$expires, auto_groups:[$gid], usage_limit:0, ephemeral:true}')"

  local key
  key="$(api_post "/setup-keys" "${payload}" | jq -r '.key')"
  if [[ -z "${key}" || "${key}" == "null" ]]; then
    log_error "Failed to create setup key ${key_name}"
    exit 1
  fi
  echo "${key}" > "${out_file}"
  chmod 600 "${out_file}"
  log_success "Setup key ${key_name} -> ${out_file}"
}

# Create or verify a network route.
ensure_route() {
  local route_id="$1"
  local network_cidr="$2"
  local router_group_id="$3"
  local devops_group_id="$4"

  local existing
  existing="$(api_get "/routes" | jq -r --arg nid "${route_id}" \
    '.[] | select(.network_id==$nid) | .id' | head -1)"
  if [[ -n "${existing}" ]]; then
    log_info "Route ${route_id} already exists (${existing})"
    echo "${existing}"
    return 0
  fi

  local result
  result="$(api_post "/routes" "$(jq -n \
    --arg nid "${route_id}" \
    --arg net "${network_cidr}" \
    --arg rg "${router_group_id}" \
    --arg dg "${devops_group_id}" \
    '{description:("Bastion PoC route for "+$nid), network_id:$nid, enabled:true,
      network:$net, metric:9999, masquerade:true,
      peer_groups:[$rg], groups:[$dg], keep_route:true}')")"
  local created_id
  created_id="$(echo "${result}" | jq -r '.id')"
  log_success "Route ${route_id} (${network_cidr}) created: ${created_id}"
  echo "${created_id}"
}

# Create ACL policy.
ensure_policy() {
  local devops_group_id="$1"
  local router_group_id="$2"

  local existing
  existing="$(api_get "/policies" | jq -r --arg n "${BASTION_POLICY_NAME}" \
    '.[] | select(.name==$n) | .id' | head -1)"
  if [[ -n "${existing}" ]]; then
    log_info "Policy ${BASTION_POLICY_NAME} already exists (${existing})"
    return 0
  fi

  api_post "/policies" "$(jq -n \
    --arg name "${BASTION_POLICY_NAME}" \
    --arg dg "${devops_group_id}" \
    --arg rg "${router_group_id}" \
    '{name:$name, description:"DevOps to bastion routers (bastion PoC)", enabled:true,
      rules:[{name:"devops-to-bastion", description:"allow all traffic",
              enabled:true, action:"accept", bidirectional:true, protocol:"all",
              sources:[$dg], destinations:[$rg]}]}')" >/dev/null
  log_success "Policy ${BASTION_POLICY_NAME}: ${BASTION_DEVOPS_GROUP} -> ${BASTION_ROUTERS_GROUP}"
}

# ── PHASES ───────────────────────────────────────────────────
run_base_bootstrap() {
  PAT="$(cat "${PAT_FILE}")"

  log_info "Ensuring groups"
  local gid_bastion gid_devops
  gid_bastion="$(ensure_group "${BASTION_ROUTERS_GROUP}")"
  gid_devops="$(ensure_group "${BASTION_DEVOPS_GROUP}")"
  log_success "Groups: ${BASTION_ROUTERS_GROUP}=${gid_bastion} ${BASTION_DEVOPS_GROUP}=${gid_devops}"

  # Persist group IDs for the --routes phase
  cat > "${STATE_FILE}" <<EOF
GID_BASTION="${gid_bastion}"
GID_DEVOPS="${gid_devops}"
EOF

  log_info "Ensuring setup keys"
  ensure_setup_key "bastion-server" "${gid_bastion}" "${BASTION_SETUP_KEY_FILE}"
  ensure_setup_key "devops-bastion" "${gid_devops}" "${BASTION_DEVOPS_KEY_FILE}"

  log_success "Base bootstrap complete. Keys in ${KEYS_DIR}/"
}

run_routes_bootstrap() {
  PAT="$(cat "${PAT_FILE}")"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  log_info "Creating route + ACL policy"
  local route_internal_id
  route_internal_id="$(ensure_route "${BASTION_ROUTE_ID}" "${BASTION_VM_SUBNET}" "${GID_BASTION}" "${GID_DEVOPS}")"
  ensure_policy "${GID_DEVOPS}" "${GID_BASTION}"

  # Save route internal ID for test script (to disable/enable route)
  echo "${route_internal_id}" > "${KEYS_DIR}/bastion-route.id"
  log_success "Route + policy ready. Route ID saved to ${KEYS_DIR}/bastion-route.id"
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_prerequisites

  if [[ "${DO_ROUTES}" == "true" ]]; then
    run_routes_bootstrap
  else
    run_base_bootstrap
  fi
}

main "$@"
