#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  gen-certs.sh
# PURPOSE: Generate a local self-signed CA and a server certificate for
#          the NetBird control plane domain (default netbird.local).
#          The CA cert is later trusted by every NetBird agent + the host
#          browser so TLS to the dashboard / management API validates.
# USAGE:   ./netbird/gen-certs.sh [--force]
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-netbird.local}"
CERT_DIR="${CERT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs}"
CA_DAYS="${CA_DAYS:-3650}"
CERT_DAYS="${CERT_DAYS:-825}"   # <= 825 keeps modern TLS clients happy
KEY_BITS="${KEY_BITS:-4096}"

# ── CONSTANTS ────────────────────────────────────────────────
readonly CA_KEY="${CERT_DIR}/rootCA-key.pem"
readonly CA_CERT="${CERT_DIR}/rootCA.pem"
readonly SERVER_KEY="${CERT_DIR}/${NETBIRD_DOMAIN}-key.pem"
readonly SERVER_CSR="${CERT_DIR}/${NETBIRD_DOMAIN}.csr"
readonly SERVER_CERT="${CERT_DIR}/${NETBIRD_DOMAIN}.pem"

FORCE_REGEN="false"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) FORCE_REGEN="true"; shift ;;
      --help)  echo "Usage: $(basename "$0") [--force]"; exit 0 ;;
      *)       log_error "Unknown argument: $1"; exit 1 ;;
    esac
  done
}

generate_ca() {
  if [[ -f "${CA_CERT}" && "${FORCE_REGEN}" != "true" ]]; then
    log_info "CA already exists at ${CA_CERT} (use --force to regenerate)"
    return 0
  fi

  log_info "Generating self-signed root CA (${KEY_BITS}-bit, ${CA_DAYS} days)"
  openssl genrsa -out "${CA_KEY}" "${KEY_BITS}"
  openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days "${CA_DAYS}" \
    -subj "/C=US/O=NetBird PoC Local CA/CN=NetBird PoC Root CA" \
    -out "${CA_CERT}"
  log_success "Root CA created: ${CA_CERT}"
}

generate_server_cert() {
  if [[ -f "${SERVER_CERT}" && "${FORCE_REGEN}" != "true" ]]; then
    log_info "Server cert already exists at ${SERVER_CERT} (use --force to regenerate)"
    return 0
  fi

  log_info "Generating server certificate for ${NETBIRD_DOMAIN}"
  openssl genrsa -out "${SERVER_KEY}" "${KEY_BITS}"
  openssl req -new -key "${SERVER_KEY}" \
    -subj "/C=US/O=NetBird PoC/CN=${NETBIRD_DOMAIN}" \
    -out "${SERVER_CSR}"

  # SANs are mandatory; CN alone is ignored by modern TLS clients.
  cat > "${CERT_DIR}/${NETBIRD_DOMAIN}.ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${NETBIRD_DOMAIN}
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

  openssl x509 -req -in "${SERVER_CSR}" \
    -CA "${CA_CERT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${SERVER_CERT}" -days "${CERT_DAYS}" -sha256 \
    -extfile "${CERT_DIR}/${NETBIRD_DOMAIN}.ext"

  # Caddy expects a full chain; append the CA so intermediates resolve.
  cat "${CA_CERT}" >> "${SERVER_CERT}"

  log_success "Server certificate created: ${SERVER_CERT}"
}

print_trust_hint() {
  log_info "To trust this CA on macOS (for the dashboard in your browser):"
  echo "    sudo security add-trusted-cert -d -r trustRoot \\"
  echo "      -k /Library/Keychains/System.keychain \"${CA_CERT}\""
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  parse_args "$@"
  mkdir -p "${CERT_DIR}"
  generate_ca
  generate_server_cert
  print_trust_hint
  log_success "Certificate generation complete"
}

main "$@"
