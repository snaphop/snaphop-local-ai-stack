#!/usr/bin/env bash
# ==============================================================================
# SnapHop Local AI Stack - Admin User Bootstrap Script
# ==============================================================================
# Ensures that at least one proxy_admin user exists with a password so that
# Web UI login works immediately, even when disable_env_credential_login is true.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
fi

LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
LITELLM_ADMIN_EMAIL="${1:-${LITELLM_ADMIN_EMAIL:-admin@example.com}}"
LITELLM_ADMIN_PASSWORD="${2:-${LITELLM_ADMIN_PASSWORD:-}}"

if [ -z "$LITELLM_MASTER_KEY" ]; then
    echo "Error: LITELLM_MASTER_KEY is not defined. Please check .env file."
    exit 1
fi

echo "Waiting for LiteLLM to be ready on port ${LITELLM_PORT}..."
MAX_RETRIES=30
RETRY_COUNT=0
until [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${LITELLM_PORT}/health/readiness" 2>/dev/null || true)" = "200" ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "Error: LiteLLM did not become healthy within 60 seconds."
        exit 1
    fi
    sleep 2
done

echo "Checking existing administrative accounts in LiteLLM..."
EXISTING_ADMINS=$(curl -s -X GET "http://127.0.0.1:${LITELLM_PORT}/user/list" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    | jq -r '.users[]? | select(.user_email != null and .user_role == "proxy_admin") | .user_email' 2>/dev/null || true)

if [ -n "$EXISTING_ADMINS" ] && echo "$EXISTING_ADMINS" | grep -qx "${LITELLM_ADMIN_EMAIL}"; then
    echo "Admin account '${LITELLM_ADMIN_EMAIL}' already exists in LiteLLM."
    echo "Bootstrap skipped (account already initialized)."
    exit 0
fi

echo "Admin account '${LITELLM_ADMIN_EMAIL}' not found. Bootstrapping admin account..."

if [ -z "$LITELLM_ADMIN_PASSWORD" ]; then
    if [ -t 0 ]; then
        echo "Please set a password for admin user '${LITELLM_ADMIN_EMAIL}':"
        read -s -p "Password: " LITELLM_ADMIN_PASSWORD
        echo ""
    else
        LITELLM_ADMIN_PASSWORD=$(openssl rand -base64 16)
        echo "=========================================================="
        echo " Generated temporary password for ${LITELLM_ADMIN_EMAIL}:"
        echo "   ${LITELLM_ADMIN_PASSWORD}"
        echo " Save this password or set LITELLM_ADMIN_PASSWORD in .env"
        echo "=========================================================="
    fi
fi

# 1. Create user in LiteLLM
echo "Creating user '${LITELLM_ADMIN_EMAIL}'..."
CREATE_RESP=$(curl -s -X POST "http://127.0.0.1:${LITELLM_PORT}/user/new" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -d "{\"user_email\": \"${LITELLM_ADMIN_EMAIL}\", \"user_role\": \"proxy_admin\"}")

# 2. Update user with password
echo "Setting password for '${LITELLM_ADMIN_EMAIL}'..."
UPDATE_RESP=$(curl -s -X POST "http://127.0.0.1:${LITELLM_PORT}/user/update" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -d "{\"user_email\": \"${LITELLM_ADMIN_EMAIL}\", \"password\": \"${LITELLM_ADMIN_PASSWORD}\"}")

# 3. Verify login
LOGIN_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:${LITELLM_PORT}/login" \
    -F "username=${LITELLM_ADMIN_EMAIL}" \
    -F "password=${LITELLM_ADMIN_PASSWORD}")

if [ "$LOGIN_HTTP_CODE" = "303" ]; then
    echo "=========================================================="
    echo "Admin account '${LITELLM_ADMIN_EMAIL}' bootstrapped successfully!"
    echo "Web UI: http://localhost:${LITELLM_PORT}/ui"
    echo "=========================================================="
else
    echo "Warning: Verification login returned HTTP code $LOGIN_HTTP_CODE."
    echo "Create response: $CREATE_RESP"
    echo "Update response: $UPDATE_RESP"
fi
