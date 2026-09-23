#!/usr/bin/env bash
#
# deploy.sh - Deploy/update the MISP stack on a provisioned VM using podman-compose.
#
# Idempotent: pulls images and (re)creates only what changed. Safe to re-run for updates.
#
# Assumes provision.sh has already run (podman, registries, ports, linger).
# Run from anywhere; paths are resolved relative to the repo root.
#
# Handles the staged startup discovered during compatibility testing:
# misp-modules is slow to become healthy, and misp-core depends on it
# (depends_on: service_healthy). We bring modules up first, wait for health,
# then start core — avoiding the "dependency failed to start" race.
#
# Usage:
#   ./deploy.sh              # deploy/update the full stack
#   ./deploy.sh --with-guard # also start the optional misp-guard (compose profile)
#
set -euo pipefail

log() { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy] WARN:\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[deploy] ERROR:\033[0m %s\n' "$*" >&2; }

# --- Resolve repo root (two levels up from this script) ---------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"
log "Repo root: ${REPO_ROOT}"

# podman-compose derives the project name from the directory name (lowercased,
# sanitized) unless COMPOSE_PROJECT_NAME is set. Container names are then
# "<project>_<service>_1". We derive it here so health checks target the right
# container regardless of the checkout directory name.
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "${REPO_ROOT}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')}"
log "Compose project: ${PROJECT}"
cname() { echo "${PROJECT}_$1_1"; }

WITH_GUARD=0
[[ "${1:-}" == "--with-guard" ]] && WITH_GUARD=1

# --- Preconditions ----------------------------------------------------------
command -v podman >/dev/null 2>&1 || { err "podman not found. Run provision.sh first."; exit 1; }
command -v podman-compose >/dev/null 2>&1 || { err "podman-compose not found. Run provision.sh first."; exit 1; }

if [[ ! -f .env ]]; then
    err ".env not found in repo root. Copy template.env to .env and configure it first."
    exit 1
fi

# --- Volume directories with correct ownership ------------------------------  [#3]
# MISP core bind-mounts these host dirs and needs to chown/chmod inside them
# (www-data, uid 33 in the image). On a native Linux fs this just works; we make
# sure the dirs exist so the first run doesn't fail on a missing path.
log "Ensuring bind-mount directories exist..."
mkdir -p configs logs files ssl gnupg
# The container runs its own chown/chmod on first boot; nothing else needed on ext4/xfs.

# --- Validate compose config ------------------------------------------------
log "Validating compose configuration..."
if ! podman-compose -f docker-compose.yml config >/dev/null 2>&1; then
    err "podman-compose config failed. Check docker-compose.yml and .env."
    podman-compose -f docker-compose.yml config 2>&1 | tail -20 >&2
    exit 1
fi

# --- Pull images ------------------------------------------------------------
# Uses *_RUNNING_TAG from .env (official pre-built images). Building locally is a
# separate concern (see Dockerfiles); here we deploy pinned images.
log "Pulling base + app images..."
podman-compose -f docker-compose.yml pull db redis mail misp-modules misp-core || \
    warn "Some pulls failed (transient network?). Continuing; up will retry."

# --- Staged startup ---------------------------------------------------------
log "Starting infrastructure services (db, redis, mail)..."
podman-compose -f docker-compose.yml up -d --no-recreate db redis mail

log "Starting misp-modules and waiting for health..."
podman-compose -f docker-compose.yml up -d --no-recreate misp-modules
wait_healthy() {
    local name="$1" timeout="${2:-180}" elapsed=0
    log "Waiting for ${name} to become healthy (timeout ${timeout}s)..."
    while [[ ${elapsed} -lt ${timeout} ]]; do
        local status
        status="$(podman inspect --format '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo 'unknown')"
        if [[ "${status}" == "healthy" ]]; then
            log "${name} is healthy."
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    warn "${name} did not reach healthy within ${timeout}s (status: ${status:-unknown}). Continuing anyway."
    return 1
}
wait_healthy "$(cname misp-modules)" 180 || true

log "Starting misp-core..."
podman-compose -f docker-compose.yml up -d --no-recreate misp-core

if [[ "${WITH_GUARD}" -eq 1 ]]; then
    log "Starting misp-guard (optional)..."
    COMPOSE_PROFILES=misp-guard podman-compose -f docker-compose.yml up -d --no-recreate misp-guard
fi

# --- Status -----------------------------------------------------------------
log "Current status:"
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

log "Deploy complete. MISP core performs first-boot initialization (data sync,"
log "config, GPG) which can take several minutes before /users/heartbeat returns 200."
log "Follow progress with:  podman logs -f $(cname misp-core)"
