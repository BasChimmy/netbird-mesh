#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# SCRIPT:  preflight.sh
# PURPOSE: Verify all host prerequisites (tools + resources) for the
#          local NetBird mesh PoC are present before bootstrapping.
# USAGE:   ./scripts/preflight.sh
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────
# Tools that MUST be present, or the PoC cannot run.
REQUIRED_TOOLS=("docker" "minikube" "kubectl" "jq" "curl" "openssl")
# Tools that are nice to have (used by some helper paths) but not fatal.
OPTIONAL_TOOLS=("make" "mysql")

# Minimum recommended host resources. Two minikube clusters plus the
# NetBird control plane are memory-hungry.
MIN_RAM_GB="${MIN_RAM_GB:-16}"
MIN_CPUS="${MIN_CPUS:-6}"

# ── CONSTANTS ────────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"

# ── FUNCTIONS ────────────────────────────────────────────────
log_info()    { echo "[INFO]  $(date '+%H:%M:%S') $*"; }
log_warn()    { echo "[WARN]  $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo "[OK]    $(date '+%H:%M:%S') $*"; }

# Detect total physical RAM in GB across macOS and Linux.
get_total_ram_gb() {
  local ram_bytes=""
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ram_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  elif [[ -r /proc/meminfo ]]; then
    local ram_kb
    ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    ram_bytes=$(( ram_kb * 1024 ))
  fi
  echo $(( ram_bytes / 1024 / 1024 / 1024 ))
}

# Detect logical CPU count across macOS and Linux.
get_cpu_count() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sysctl -n hw.ncpu 2>/dev/null || echo 0
  else
    nproc 2>/dev/null || echo 0
  fi
}

check_required_tools() {
  local missing_tools=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if command -v "${tool}" &>/dev/null; then
      log_success "found required tool: ${tool} -> $(command -v "${tool}")"
    else
      log_error "missing required tool: ${tool}"
      missing_tools+=("${tool}")
    fi
  done

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Install the missing tools and re-run: ${missing_tools[*]}"
    return 1
  fi
}

check_optional_tools() {
  for tool in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "${tool}" &>/dev/null; then
      log_success "found optional tool: ${tool}"
    else
      log_warn "optional tool not found (some convenience paths disabled): ${tool}"
    fi
  done
}

check_docker_daemon() {
  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not reachable. Start Docker/Rancher Desktop first."
    return 1
  fi
  log_success "Docker daemon is reachable"
}

check_resources() {
  local total_ram_gb total_cpus
  total_ram_gb="$(get_total_ram_gb)"
  total_cpus="$(get_cpu_count)"

  if [[ "${total_ram_gb}" -lt "${MIN_RAM_GB}" ]]; then
    log_warn "Detected ${total_ram_gb}GB RAM; ${MIN_RAM_GB}GB recommended. Clusters may be unstable."
  else
    log_success "RAM: ${total_ram_gb}GB (>= ${MIN_RAM_GB}GB recommended)"
  fi

  if [[ "${total_cpus}" -lt "${MIN_CPUS}" ]]; then
    log_warn "Detected ${total_cpus} CPUs; ${MIN_CPUS} recommended."
  else
    log_success "CPUs: ${total_cpus} (>= ${MIN_CPUS} recommended)"
  fi
}

# ── MAIN ─────────────────────────────────────────────────────
main() {
  log_info "Running ${SCRIPT_NAME} — checking PoC prerequisites"

  check_required_tools
  check_optional_tools
  check_docker_daemon
  check_resources

  log_success "Preflight complete — host is ready for the NetBird PoC"
}

main "$@"
