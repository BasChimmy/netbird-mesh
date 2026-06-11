#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  netbird-up.sh
# PURPOSE: Render config from templates (generating secrets), ensure the
#          self-signed CA exists, verify the /etc/hosts entry, and start
#          the local NetBird control plane via docker compose.
# USAGE:   ./netbird/netbird-up.sh [--down] [--logs]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@netbird.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-NetBirdAdmin1!}"

# ── CONSTANTS ────────────────────────────────────────────────
readonly NETBIRD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CERT_DIR="${NETBIRD_DIR}/certs"
readonly CA_CERT="${CERT_DIR}/rootCA.pem"
readonly CONFIG_TMPL="${NETBIRD_DIR}/config.yaml.tmpl"
readonly CONFIG_OUT="${NETBIRD_DIR}/config.yaml"
readonly DASHBOARD_TMPL="${NETBIRD_DIR}/dashboard.env.tmpl"
readonly DASHBOARD_OUT="${NETBIRD_DIR}/dashboard.env"
readonly SECRETS_FILE="${NETBIRD_DIR}/.keys/control-plane.secrets"

ACTION="up"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --down) ACTION="down"; shift ;;
      --logs) ACTION="logs"; shift ;;
      --help) echo "Usage: $(basename "$0") [--down] [--logs]"; exit 0 ;;
      *)      log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

check_prerequisites() {
  local required_tools=("docker" "openssl")
  for tool in "${required_tools[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
      log_error "Required tool not found: ${tool}"
      exit 1
    fi
  done
  if ! docker compose version &>/dev/null; then
    log_error "docker compose v2 plugin is required"
    exit 1
  fi
}

check_hosts_entry() {
  if grep -qE "^[^#]*[[:space:]]${NETBIRD_DOMAIN}(\$|[[:space:]])" /etc/hosts; then
    log_success "/etc/hosts already maps ${NETBIRD_DOMAIN}"
    return 0
  fi
  log_warn "${NETBIRD_DOMAIN} is not in /etc/hosts."
  log_warn "Add it so the dashboard + agents resolve the control plane:"
  echo "    echo '127.0.0.1 ${NETBIRD_DOMAIN}' | sudo tee -a /etc/hosts"
}

# Generate a base64 32-byte key suitable for store/cookie encryption.
generate_b64_key() {
  openssl rand -base64 32
}

ensure_secrets() {
  mkdir -p "$(dirname "${SECRETS_FILE}")"
  if [[ -f "${SECRETS_FILE}" ]]; then
    log_info "Reusing existing control-plane secrets"
    # shellcheck disable=SC1090
    source "${SECRETS_FILE}"
    return 0
  fi

  log_info "Generating control-plane secrets"
  RELAY_AUTH_SECRET="$(generate_b64_key)"
  STORE_ENCRYPTION_KEY="$(generate_b64_key)"
  IDP_COOKIE_KEY="$(generate_b64_key)"

  cat > "${SECRETS_FILE}" <<EOF
RELAY_AUTH_SECRET="${RELAY_AUTH_SECRET}"
STORE_ENCRYPTION_KEY="${STORE_ENCRYPTION_KEY}"
IDP_COOKIE_KEY="${IDP_COOKIE_KEY}"
EOF
  chmod 600 "${SECRETS_FILE}"
  log_success "Secrets written to ${SECRETS_FILE}"
}

render_templates() {
  log_info "Rendering config.yaml and dashboard.env"

  sed \
    -e "s|__NETBIRD_DOMAIN__|${NETBIRD_DOMAIN}|g" \
    -e "s|__RELAY_AUTH_SECRET__|${RELAY_AUTH_SECRET}|g" \
    -e "s|__STORE_ENCRYPTION_KEY__|${STORE_ENCRYPTION_KEY}|g" \
    -e "s|__IDP_COOKIE_KEY__|${IDP_COOKIE_KEY}|g" \
    "${CONFIG_TMPL}" > "${CONFIG_OUT}"

  sed \
    -e "s|__NETBIRD_DOMAIN__|${NETBIRD_DOMAIN}|g" \
    "${DASHBOARD_TMPL}" > "${DASHBOARD_OUT}"

  log_success "Config rendered"
}

ensure_certs() {
  if [[ -f "${CA_CERT}" ]]; then
    log_info "CA certificate already present"
    return 0
  fi
  log_info "Generating self-signed CA + server cert"
  NETBIRD_DOMAIN="${NETBIRD_DOMAIN}" CERT_DIR="${CERT_DIR}" \
    bash "${NETBIRD_DIR}/gen-certs.sh"
}

compose_up() {
  log_info "Starting NetBird control plane"
  docker compose -f "${NETBIRD_DIR}/docker-compose.yml" up -d
  log_success "Control plane starting. Dashboard: https://${NETBIRD_DOMAIN}"
  log_info "Next: bootstrap the owner + PAT via ./netbird/netbird-bootstrap.sh"
}

compose_down() {
  log_info "Stopping NetBird control plane"
  docker compose -f "${NETBIRD_DIR}/docker-compose.yml" down
  log_success "Control plane stopped"
}

compose_logs() {
  docker compose -f "${NETBIRD_DIR}/docker-compose.yml" logs -f --tail=100
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_prerequisites

  if [[ "${ACTION}" == "down" ]]; then
    compose_down
    exit 0
  fi
  if [[ "${ACTION}" == "logs" ]]; then
    compose_logs
    exit 0
  fi

  ensure_certs
  ensure_secrets
  render_templates
  check_hosts_entry
  compose_up
}

main "$@"
