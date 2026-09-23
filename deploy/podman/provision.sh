#!/usr/bin/env bash
#
# provision.sh - Prepare a fresh Linux VM to run MISP with rootless Podman + systemd.
#
# Idempotent: safe to re-run. Detects Debian/Ubuntu (apt) or RHEL/Fedora (dnf).
#
# What it does:
#   1. Installs podman + podman-compose.
#   2. Configures unqualified-search-registries so short image names resolve
#      (Podman does not assume Docker Hub, unlike Docker).           [adjustment #1]
#   3. Allows binding privileged ports (80/443) from rootless Podman. [adjustment #2]
#   4. Enables systemd lingering so the stack starts at boot without an
#      interactive login for the service user.
#
# Volume permissions (adjustment #3) are handled by deploy.sh, since they depend
# on the checkout location. On a native Linux filesystem (ext4/xfs) they work as
# expected — the "permission denied" seen under WSL/DrvFS does not occur here.
#
# Usage (run as the user that will own the stack, with sudo available):
#   ./provision.sh
#
set -euo pipefail

log() { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[provision] WARN:\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[provision] ERROR:\033[0m %s\n' "$*" >&2; }

if [[ "${EUID}" -eq 0 ]]; then
    warn "Running as root. Rootless Podman is recommended; consider running as a dedicated non-root user."
fi

# --- Detect package manager -------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
else
    err "Unsupported distro: neither apt-get nor dnf found."
    exit 1
fi
log "Detected package manager: ${PKG_MGR}"

# --- 1. Install podman + podman-compose -------------------------------------
install_packages() {
    if command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1; then
        log "podman ($(podman --version)) and podman-compose already installed, skipping."
        return
    fi
    log "Installing podman and podman-compose..."
    if [[ "${PKG_MGR}" == "apt" ]]; then
        sudo apt-get update
        sudo apt-get install -y podman podman-compose
    else
        sudo dnf install -y podman podman-compose
    fi
}
install_packages
log "podman:         $(podman --version)"
log "podman-compose: $(podman-compose --version 2>/dev/null | head -1 || echo 'n/a')"

# --- 2. Registries: resolve unqualified image names -------------------------  [#1]
# The compose file uses short names like 'mariadb:10.11' and 'valkey/valkey:7.2'.
# Podman needs an explicit search registry or it errors with "short-name did not resolve".
configure_registries() {
    local conf="/etc/containers/registries.conf"
    if [[ -f "${conf}" ]] && grep -qE '^\s*unqualified-search-registries\s*=\s*\[.*docker\.io.*\]' "${conf}"; then
        log "unqualified-search-registries already configured, skipping."
        return
    fi
    log "Configuring docker.io as unqualified search registry (system-wide)..."
    sudo mkdir -p /etc/containers/registries.conf.d
    sudo tee /etc/containers/registries.conf.d/00-misp-unqualified.conf >/dev/null <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF
}
configure_registries

# --- 3. Allow rootless binding of privileged ports (80/443) -----------------  [#2]
# Rootless Podman cannot bind ports < 1024 by default. MISP core listens on 80/443.
# Lowering the threshold to 80 lets the compose ports "80:80"/"443:443" work rootless.
# Alternative (not applied here): map to high ports and put a reverse proxy in front.
configure_ports() {
    local sysctl_file="/etc/sysctl.d/99-misp-unprivileged-ports.conf"
    local current
    current="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)"
    if [[ "${current}" -le 80 ]]; then
        log "Privileged ports already allowed (ip_unprivileged_port_start=${current}), skipping."
        return
    fi
    log "Allowing rootless bind of ports >= 80 (currently ${current})..."
    echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee "${sysctl_file}" >/dev/null
    sudo sysctl --system >/dev/null
    log "ip_unprivileged_port_start now: $(cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"
}
configure_ports

# --- 4. Enable systemd lingering for boot-time startup ----------------------
# Lingering lets the user's systemd services (the stack) run at boot without
# an active login session. Only meaningful for rootless setups.
enable_linger() {
    if [[ "${EUID}" -eq 0 ]]; then
        warn "Running as root; skipping user lingering (not applicable)."
        return
    fi
    if loginctl show-user "${USER}" 2>/dev/null | grep -q 'Linger=yes'; then
        log "Lingering already enabled for ${USER}, skipping."
        return
    fi
    log "Enabling systemd lingering for ${USER}..."
    sudo loginctl enable-linger "${USER}"
}
enable_linger

log "Provisioning complete."
log "Next: copy your .env into the repo root and run ./deploy/podman/deploy.sh"
