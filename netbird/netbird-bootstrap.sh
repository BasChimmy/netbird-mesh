#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  netbird-bootstrap.sh
# PURPOSE: Drive the NetBird API to make the PoC reproducible:
#            1. create the first owner + a Personal Access Token (PAT)
#            2. create groups (per-cluster routers + devops)
#            3. create reusable+ephemeral setup keys for each group
#            4. create network routes (one per cluster CIDR)
#            5. create an ACL policy: devops -> both router groups
#
# Phases 4-5 require the routing peers to have registered first (so the
# router groups contain at least one peer). Run with --routes after the
# cluster routing peers are up.
#
# USAGE:   ./netbird/netbird-bootstrap.sh            # owner, PAT, groups, keys
#          ./netbird/netbird-bootstrap.sh --routes   # add routes + ACL policy
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
readonly BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR="$(cd "${BOOTSTRAP_DIR}/../scripts" && pwd)"
# shellcheck source=../scripts/config.sh
source "${SCRIPTS_DIR}/config.sh"

readonly CA_CERT="${BOOTSTRAP_DIR}/certs/rootCA.pem"
readonly KEYS_OUT_DIR="${BOOTSTRAP_DIR}/.keys"
readonly PAT_FILE="${KEYS_OUT_DIR}/admin.pat"
readonly STATE_FILE="${KEYS_OUT_DIR}/bootstrap.state"

# curl args that pin our CA and resolve the local domain to 127.0.0.1.
CURL_BASE=(curl -fsS --cacert "${CA_CERT}" --resolve "${NETBIRD_DOMAIN}:443:127.0.0.1")
API="https://${NETBIRD_DOMAIN}/api"

DO_ROUTES="false"

# Setup key lifetime: 1 year (max allowed by API is 31536000s).
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
  for tool in curl jq; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
  [[ -f "${CA_CERT}" ]] || { log_error "CA cert missing: ${CA_CERT}"; exit 1; }
  mkdir -p "${KEYS_OUT_DIR}"
}

# Authenticated API helpers ───────────────────────────────────
api_get() {
  "${CURL_BASE[@]}" -H "Authorization: Token ${PAT}" "${API}$1"
}
api_post() {
  "${CURL_BASE[@]}" -H "Authorization: Token ${PAT}" \
    -H "Content-Type: application/json" -X POST "${API}$1" --data-raw "$2"
}

# Bootstrap the first owner + PAT (only works before setup completes).
bootstrap_owner_pat() {
  if [[ -f "${PAT_FILE}" ]]; then
    PAT="$(cat "${PAT_FILE}")"
    log_info "Reusing existing PAT from ${PAT_FILE}"
    return 0
  fi

  log_info "Creating first owner + PAT via /api/setup"
  local response
  response="$("${CURL_BASE[@]}" -X POST "${API}/setup" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"name\":\"${ADMIN_NAME}\",\"password\":\"${ADMIN_PASSWORD}\",\"create_pat\":true,\"pat_expire_in\":365}")" \
    || { log_error "Setup API call failed (already completed? wipe netbird_data volume to retry)"; exit 1; }

  PAT="$(echo "${response}" | jq -r '.personal_access_token // empty')"
  if [[ -z "${PAT}" ]]; then
    log_error "No PAT in setup response: ${response}"
    exit 1
  fi
  echo "${PAT}" > "${PAT_FILE}"
  chmod 600 "${PAT_FILE}"
  log_success "Owner created; PAT saved to ${PAT_FILE}"
}

# Return the group ID for a given name, creating the group if absent.
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

# Create a reusable+ephemeral setup key in one group; write key to a file.
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

# Phase 1-3: owner, groups, keys.
run_base_bootstrap() {
  bootstrap_owner_pat

  log_info "Ensuring groups"
  local gid_a gid_b gid_devops
  gid_a="$(ensure_group "${NETBIRD_ROUTERS_GROUP_A}")"
  gid_b="$(ensure_group "${NETBIRD_ROUTERS_GROUP_B}")"
  gid_devops="$(ensure_group "${NETBIRD_DEVOPS_GROUP}")"
  log_success "Groups: ${NETBIRD_ROUTERS_GROUP_A}=${gid_a} ${NETBIRD_ROUTERS_GROUP_B}=${gid_b} ${NETBIRD_DEVOPS_GROUP}=${gid_devops}"

  # Persist group IDs for the --routes phase.
  cat > "${STATE_FILE}" <<EOF
GID_ROUTERS_A="${gid_a}"
GID_ROUTERS_B="${gid_b}"
GID_DEVOPS="${gid_devops}"
EOF

  log_info "Ensuring setup keys"
  ensure_setup_key "router-clusterA" "${gid_a}" "${KEYS_OUT_DIR}/router-a.key"
  ensure_setup_key "router-clusterB" "${gid_b}" "${KEYS_OUT_DIR}/router-b.key"
  ensure_setup_key "devops-server"   "${gid_devops}" "${KEYS_OUT_DIR}/devops.key"

  log_success "Base bootstrap complete. Setup keys in ${KEYS_OUT_DIR}/"
}

# Create or update a network route advertising one CIDR via a router group.
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
    return 0
  fi

  # masquerade=true so DB pods see the router as the traffic source and
  # need no return route. peer_groups = the cluster's routing peers;
  # groups = distribution groups that receive the route (the devops peer).
  api_post "/routes" "$(jq -n \
    --arg nid "${route_id}" \
    --arg net "${network_cidr}" \
    --arg rg "${router_group_id}" \
    --arg dg "${devops_group_id}" \
    '{description:("PoC route for "+$nid), network_id:$nid, enabled:true,
      network:$net, metric:9999, masquerade:true,
      peer_groups:[$rg], groups:[$dg], keep_route:true}')" >/dev/null
  log_success "Route ${route_id} (${network_cidr}) via group ${router_group_id}"
}

# Create the ACL policy: devops -> both router groups (all TCP).
ensure_policy() {
  local devops_group_id="$1"
  local router_group_a="$2"
  local router_group_b="$3"
  local policy_name="devops-to-k8s"

  local existing
  existing="$(api_get "/policies" | jq -r --arg n "${policy_name}" \
    '.[] | select(.name==$n) | .id' | head -1)"
  if [[ -n "${existing}" ]]; then
    log_info "Policy ${policy_name} already exists (${existing})"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "${policy_name}" \
    --arg dg "${devops_group_id}" \
    --arg ra "${router_group_a}" \
    --arg rb "${router_group_b}" \
    '{name:$name, description:"DevOps server to k8s routers", enabled:true,
      rules:[{name:"devops-to-routers", description:"allow devops to both clusters",
              enabled:true, action:"accept", bidirectional:true, protocol:"all",
              sources:[$dg], destinations:[$ra,$rb]}]}')"

  api_post "/policies" "${payload}" >/dev/null
  log_success "Policy ${policy_name}: ${NETBIRD_DEVOPS_GROUP} -> routers (A+B)"
}

# Phase 4-5: routes + ACL (run after routing peers register).
run_routes_bootstrap() {
  [[ -f "${PAT_FILE}" ]] || { log_error "Run base bootstrap first"; exit 1; }
  PAT="$(cat "${PAT_FILE}")"
  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  log_info "Creating routes + ACL policy"
  ensure_route "${NETBIRD_ROUTE_ID_A}" "${CLUSTER_A_SERVICE_CIDR}" "${GID_ROUTERS_A}" "${GID_DEVOPS}"
  ensure_route "${NETBIRD_ROUTE_ID_B}" "${CLUSTER_B_SERVICE_CIDR}" "${GID_ROUTERS_B}" "${GID_DEVOPS}"
  ensure_policy "${GID_DEVOPS}" "${GID_ROUTERS_A}" "${GID_ROUTERS_B}"
  log_success "Routes + ACL policy ready"
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
