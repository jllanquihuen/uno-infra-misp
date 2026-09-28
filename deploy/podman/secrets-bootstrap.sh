#!/usr/bin/env bash
#
# secrets-bootstrap.sh - Hydrate the MISP .env from AWS Secrets Manager.
#
# Reads one (or more) Secrets Manager secrets whose value is a JSON object of
# key -> value pairs, and upserts each key into the .env file (replacing the
# value if the key exists, appending it otherwise). The .env is written with
# 0600 permissions so plaintext secrets never sit world-readable.
#
# The instance reads secrets using its IAM role (secretsmanager:GetSecretValue),
# so no AWS credentials are stored on disk.
#
# Typical secret payload (prod/misp/app):
#   {
#     "MYSQL_PASSWORD": "...",
#     "MYSQL_ROOT_PASSWORD": "...",
#     "REDIS_PASSWORD": "...",
#     "GPG_PASSPHRASE": "...",
#     "ADMIN_PASSWORD": "...",
#     "OIDC_CLIENT_SECRET": "...",
#     "SMARTHOST_PASSWORD": "...",
#     "S3_SECRET_KEY": "..."
#   }
#
# Usage:
#   ./secrets-bootstrap.sh                          # uses defaults below
#   MISP_SECRET_ID=prod/misp/app AWS_REGION=us-east-1 ./secrets-bootstrap.sh
#   ./secrets-bootstrap.sh prod/misp/app prod/misp/oidc   # multiple secrets, merged
#
# Requires: aws CLI v2, jq.
#
set -euo pipefail

log() { printf '\033[1;34m[secrets]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[secrets] ERROR:\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Secret IDs: from CLI args, or MISP_SECRET_ID env, or a sensible default.
if [[ "$#" -gt 0 ]]; then
    SECRET_IDS=("$@")
else
    SECRET_IDS=("${MISP_SECRET_ID:-prod/misp/app}")
fi

# --- Preconditions ----------------------------------------------------------
command -v aws >/dev/null 2>&1 || { err "aws CLI not found."; exit 1; }
command -v jq  >/dev/null 2>&1 || { err "jq not found (needed to parse the secret JSON)."; exit 1; }

if [[ ! -f "${ENV_FILE}" ]]; then
    err ".env not found at ${ENV_FILE}. Copy template.env to .env first."
    exit 1
fi

# --- upsert KEY=VALUE into .env ---------------------------------------------
# Replaces an existing (even commented) definition or appends a new one.
upsert_env() {
    local key="$1" value="$2"
    # Escape characters special to sed replacement (& and the delimiter |).
    local esc
    esc="$(printf '%s' "${value}" | sed -e 's/[&|\\]/\\&/g')"
    if grep -qE "^#?\s*${key}=" "${ENV_FILE}"; then
        sed -i -E "s|^#?\s*${key}=.*|${key}=${esc}|" "${ENV_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
    fi
}

# --- Fetch + merge each secret ----------------------------------------------
umask 077   # anything we create is not world-readable
tmp_json="$(mktemp)"
trap 'rm -f "${tmp_json}"' EXIT

total_keys=0
for sid in "${SECRET_IDS[@]}"; do
    log "Fetching secret: ${sid} (region ${AWS_REGION})"
    if ! aws secretsmanager get-secret-value \
            --secret-id "${sid}" \
            --region "${AWS_REGION}" \
            --query 'SecretString' --output text > "${tmp_json}" 2>/dev/null; then
        err "Could not read secret '${sid}'. Check the name, region and IAM permissions."
        exit 1
    fi

    if ! jq -e 'type == "object"' "${tmp_json}" >/dev/null 2>&1; then
        err "Secret '${sid}' is not a JSON object of key/value pairs."
        exit 1
    fi

    # Iterate keys of the JSON object and upsert each into .env.
    while IFS= read -r key; do
        value="$(jq -r --arg k "${key}" '.[$k]' "${tmp_json}")"
        upsert_env "${key}" "${value}"
        total_keys=$((total_keys + 1))
        log "  set ${key}"
    done < <(jq -r 'keys[]' "${tmp_json}")
done

chmod 600 "${ENV_FILE}"
log "Done. Upserted ${total_keys} key(s) into ${ENV_FILE} (chmod 600)."
