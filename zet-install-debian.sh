#!/usr/bin/env bash
# install-ziti-edge-tunnel.sh
# Installs OpenZiti ziti-edge-tunnel on Debian/Ubuntu (systemd hosts).
# Reference: https://openziti.io/docs/reference/tunnelers/linux/debian-package/

set -Eeuo pipefail

# -------- config --------
IDENTITY_JWT="${IDENTITY_JWT:-}"      # optional path to enrollment .jwt
APT_LIST="/etc/apt/sources.list.d/openziti.list"
KEYRING="/usr/share/keyrings/openziti.gpg"
LOG_FILE="${LOG_FILE:-/var/log/ziti-edge-tunnel-install.log}"

# -------- logging --------
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" || { echo "Cannot write log: $LOG_FILE"; exit 1; }
exec > >(awk '{print strftime("[%Y-%m-%d %H:%M:%S]"),$0} { fflush() }' | tee -a "$LOG_FILE") 2>&1

log()      { printf '%s %s\n' "[INFO]" "$*"; }
warn()     { printf '%s %s\n' "[WARN]" "$*"; }
error()    { printf '%s %s\n' "[ERROR]" "$*" >&2; }
log_step() { printf '\n=== %s ===\n' "$*"; }

trap 'error "failed at line $LINENO: $BASH_COMMAND"; exit 99' ERR

[[ $EUID -eq 0 ]] || { error "Run as root (use sudo)."; exit 1; }

log_step "Detect OS"
source /etc/os-release || { error "Missing /etc/os-release"; exit 1; }
log "ID=$ID ID_LIKE=${ID_LIKE:-} VERSION_CODENAME=${VERSION_CODENAME:-} VERSION_ID=${VERSION_ID:-}"

UBUNTU_LTS=""
case "${ID_LIKE:-$ID}" in
  *ubuntu*|ubuntu)
    UBUNTU_LTS="${VERSION_CODENAME}"
    ;;
  *debian*|debian)
    deb_major="${VERSION_ID%%.*}"
    if [[ -n "$deb_major" && "$deb_major" -lt 10 ]]; then
      error "Unsupported Debian version (${VERSION_ID}). Debian 10+ required."
      exit 2
    fi
    case "${VERSION_CODENAME}" in
      trixie|bookworm) UBUNTU_LTS="jammy"  ;; # Debian 13/12 -> 22.04
      bullseye)        UBUNTU_LTS="focal"  ;; # Debian 11    -> 20.04
      buster)          UBUNTU_LTS="bionic" ;; # Debian 10    -> 18.04
      *)
        error "Unsupported Debian codename '${VERSION_CODENAME}'. Set UBUNTU_LTS_OVERRIDE and retry."
        exit 2
        ;;
    esac
    ;;
  *)
    error "Unsupported distro: ID=${ID} ID_LIKE=${ID_LIKE:-}"; exit 2;;
esac

# allow manual override
UBUNTU_LTS="${UBUNTU_LTS_OVERRIDE:-$UBUNTU_LTS}"
log "Using Ubuntu suite '${UBUNTU_LTS}' for OpenZiti APT repo mapping."

log_step "Install prerequisites"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates

log_step "Add OpenZiti APT key and repo"
install -d -m 0755 "$(dirname "$KEYRING")"
curl -sSLf https://get.openziti.io/tun/package-repos.gpg | gpg --dearmor -o "$KEYRING"
chmod +r "$KEYRING"
echo "deb [signed-by=${KEYRING}] https://packages.openziti.org/zitipax-openziti-deb-stable ${UBUNTU_LTS} main" \
  | tee "$APT_LIST" >/dev/null

log_step "Install ziti-edge-tunnel"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ziti-edge-tunnel
command -v ziti-edge-tunnel >/dev/null || { error "Binary not found after install"; exit 4; }

log_step "Enable and start service"
systemctl enable --now ziti-edge-tunnel.service
systemctl --no-pager --full status ziti-edge-tunnel.service || warn "Service status reported non-zero"

log_step "Optional identity enrollment (name derived from JWT filename)"
if [[ -n "$IDENTITY_JWT" ]]; then
  [[ -f "$IDENTITY_JWT" ]] || { error "JWT not found: $IDENTITY_JWT"; exit 5; }
  base="$(basename "$IDENTITY_JWT")"
  # strip extension if present (.jwt or any extension)
  IDENTITY_NAME="${base%.*}"
  ziti-edge-tunnel add --jwt "$(< "$IDENTITY_JWT")" --identity "$IDENTITY_NAME"
  log "Enrollment attempted for identity '${IDENTITY_NAME}'"
else
  log "No IDENTITY_JWT provided; skipping enrollment"
fi

log_step "Resolver note"
if systemctl is-enabled systemd-resolved &>/dev/null; then
  log "systemd-resolved enabled; Ziti DNS should auto-configure"
else
  warn "systemd-resolved not enabled; ensure resolver can reach 100.64.0.2 if using intercept DNS"
fi

log_step "Complete"
log "Logs: $LOG_FILE"