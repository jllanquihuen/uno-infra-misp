#!/usr/bin/env bash
#
# backup.sh - Logical backup of MISP to S3 (complements EBS snapshots).
#
# Two recovery levels for a production MISP:
#   1) EBS snapshot (whole /opt/misp/data volume) - fast full recovery.
#   2) This script - a portable logical backup: mysqldump of the MISP DB plus a
#      tarball of the critical files (MISP files, configs, gnupg). Uploaded to S3.
#
# What is backed up:
#   - MariaDB (mysqldump of the MISP database)
#   - MISP files       (${MISP_DATA_DIR}/files)
#   - MISP configs     (${MISP_DATA_DIR}/configs)
#   - GPG keyring      (${MISP_DATA_DIR}/gnupg)
# Redis/Valkey is a cache and is intentionally NOT prioritized here.
#
# Uses the instance IAM role for the S3 upload (no stored credentials).
#
# Usage:
#   BACKUP_S3_BUCKET=my-bucket ./backup.sh
#   BACKUP_S3_BUCKET=my-bucket BACKUP_S3_PREFIX=misp/prod ./backup.sh
#
# Env:
#   BACKUP_S3_BUCKET   (required) target S3 bucket name
#   BACKUP_S3_PREFIX   (optional) key prefix, default "misp"
#   AWS_REGION         (optional) region for the S3 upload
#   MISP_DATA_DIR      (optional) data root; read from .env if not set, default "."
#   DB_CONTAINER       (optional) MariaDB container name (auto-detected by default)
#
set -euo pipefail

log() { printf '\033[1;34m[backup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[backup] ERROR:\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

# --- Config -----------------------------------------------------------------
: "${BACKUP_S3_BUCKET:?Set BACKUP_S3_BUCKET to the target S3 bucket}"
BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-misp}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Read values from .env when present.
env_get() { grep -E "^$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2-; }
MISP_DATA_DIR="${MISP_DATA_DIR:-$(env_get MISP_DATA_DIR)}"
MISP_DATA_DIR="${MISP_DATA_DIR:-.}"
MYSQL_USER="$(env_get MYSQL_USER)"; MYSQL_USER="${MYSQL_USER:-misp}"
MYSQL_PASSWORD="$(env_get MYSQL_PASSWORD)"; MYSQL_PASSWORD="${MYSQL_PASSWORD:-example}"
MYSQL_DATABASE="$(env_get MYSQL_DATABASE)"; MYSQL_DATABASE="${MYSQL_DATABASE:-misp}"

command -v aws >/dev/null 2>&1 || { err "aws CLI not found."; exit 1; }
command -v podman >/dev/null 2>&1 || { err "podman not found."; exit 1; }

# Auto-detect the MariaDB container by compose service label if not provided.
DB_CONTAINER="${DB_CONTAINER:-$(podman ps -a \
    --filter 'label=com.docker.compose.service=db' \
    --format '{{.Names}}' 2>/dev/null | head -n1)}"
[[ -n "${DB_CONTAINER}" ]] || { err "Could not find the MariaDB container."; exit 1; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
umask 077

# --- 1) MariaDB logical dump ------------------------------------------------
log "Dumping MariaDB database '${MYSQL_DATABASE}' from ${DB_CONTAINER}..."
podman exec "${DB_CONTAINER}" \
    mysqldump --user="${MYSQL_USER}" --password="${MYSQL_PASSWORD}" \
    --single-transaction --routines --triggers "${MYSQL_DATABASE}" \
    > "${WORK}/db.sql"
gzip "${WORK}/db.sql"

# --- 2) Critical files tarball ----------------------------------------------
log "Archiving files/configs/gnupg from ${MISP_DATA_DIR}..."
tar -czf "${WORK}/data.tar.gz" -C "${MISP_DATA_DIR}" \
    $( [ -d "${MISP_DATA_DIR}/files" ]   && echo files )   \
    $( [ -d "${MISP_DATA_DIR}/configs" ] && echo configs ) \
    $( [ -d "${MISP_DATA_DIR}/gnupg" ]   && echo gnupg )   \
    2>/dev/null || true

# --- 3) Upload to S3 --------------------------------------------------------
DEST="s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${TS}"
log "Uploading to ${DEST}/ ..."
aws s3 cp "${WORK}/db.sql.gz"   "${DEST}/db.sql.gz"   --region "${AWS_REGION}"
aws s3 cp "${WORK}/data.tar.gz" "${DEST}/data.tar.gz" --region "${AWS_REGION}"

log "Backup complete: ${DEST}/"
log "Restore hints:"
log "  DB:    zcat db.sql.gz | podman exec -i ${DB_CONTAINER} mysql -u<user> -p<pass> ${MYSQL_DATABASE}"
log "  Files: tar -xzf data.tar.gz -C ${MISP_DATA_DIR}"
