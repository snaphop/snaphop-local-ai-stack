#!/usr/bin/env bash
# Ensure the configured proxy_admin can sign in with the operator password.
# An existing row is not treated as success until that password is accepted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=load_env.sh
source "$SCRIPT_DIR/load_env.sh"
load_env_file "$PROJECT_DIR/.env"

LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"
if [ -n "${EMAIL:-}" ]; then
    LITELLM_ADMIN_EMAIL="$EMAIL"
fi
if [ -n "${PASSWORD:-}" ]; then
    LITELLM_ADMIN_PASSWORD="$PASSWORD"
fi
LITELLM_ADMIN_EMAIL="${LITELLM_ADMIN_EMAIL:-admin@example.com}"
LITELLM_ADMIN_PASSWORD="${LITELLM_ADMIN_PASSWORD:-}"

if [ -z "$LITELLM_ADMIN_PASSWORD" ]; then
    if [ -t 0 ]; then
        echo "Please set a password for admin user '${LITELLM_ADMIN_EMAIL}':"
        read -r -s -p "Password: " LITELLM_ADMIN_PASSWORD
        echo ""
    fi
fi
if [ -z "$LITELLM_ADMIN_PASSWORD" ]; then
    echo "Error: Set LITELLM_ADMIN_PASSWORD in .env or pass PASSWORD for noninteractive bootstrap." >&2
    exit 1
fi
case "$LITELLM_ADMIN_PASSWORD" in
    *$'\n'*|*$'\r'*)
        echo "Error: admin password must be a single line." >&2
        exit 1
        ;;
esac

BASE_URL="http://127.0.0.1:${LITELLM_PORT}"
MAX_RETRIES=90
RETRY_COUNT=0

echo "Waiting for LiteLLM to be ready on port ${LITELLM_PORT}..."
until [ "$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health/readiness" 2>/dev/null || true)" = "200" ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "Error: LiteLLM did not become healthy within 180 seconds." >&2
        exit 1
    fi
    sleep 2
done

post_json() {
    local path="$1"
    local payload="$2"
    local body_file http_code
    body_file="$(mktemp)"
    http_code="$(printf '%s' "$payload" | curl -sS -o "$body_file" -w '%{http_code}' \
        -X POST "${BASE_URL}${path}" \
        -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
        -H "Content-Type: application/json" \
        --data-binary @-)" || {
        rm -f "$body_file"
        echo "Error: request to ${path} failed." >&2
        exit 1
    }
    rm -f "$body_file"
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Error: ${path} returned HTTP ${http_code}." >&2
        if [ "$path" = "/user/update" ]; then
            echo "LiteLLM's default password policy requires at least 12 characters with an uppercase letter, a lowercase letter, a digit, and a special character." >&2
        fi
        exit 1
    fi
}

login_code() {
    curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE_URL}/login" \
        --form-string "username=${LITELLM_ADMIN_EMAIL}" \
        --form-string "password=${LITELLM_ADMIN_PASSWORD}"
}

echo "Checking existing administrative accounts in LiteLLM..."
list_body="$(mktemp)"
list_code="$(curl -sS -o "$list_body" -w '%{http_code}' \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    "${BASE_URL}/user/list")" || {
    rm -f "$list_body"
    echo "Error: request to /user/list failed." >&2
    exit 1
}
if [ "$list_code" -lt 200 ] || [ "$list_code" -ge 300 ]; then
    rm -f "$list_body"
    echo "Error: /user/list returned HTTP ${list_code}." >&2
    exit 1
fi
existing_admins="$(jq -r '.users[]? | select(.user_email != null and .user_role == "proxy_admin") | .user_email' "$list_body")"
rm -f "$list_body"

password_payload="$(jq -n \
    --arg email "$LITELLM_ADMIN_EMAIL" \
    --arg password "$LITELLM_ADMIN_PASSWORD" \
    '{user_email: $email, user_role: "proxy_admin", password: $password}')"

if printf '%s\n' "$existing_admins" | grep -Fxq -- "$LITELLM_ADMIN_EMAIL"; then
    echo "Admin account '${LITELLM_ADMIN_EMAIL}' exists. Verifying the configured password..."
    if [ "$(login_code)" = "303" ]; then
        echo "Admin account '${LITELLM_ADMIN_EMAIL}' accepts the configured password."
        echo "Web UI: http://localhost:${LITELLM_PORT}/ui"
        exit 0
    fi
    echo "Configured password was rejected. Setting it from the operator password..."
else
    echo "Creating user '${LITELLM_ADMIN_EMAIL}'..."
    create_payload="$(jq -n \
        --arg email "$LITELLM_ADMIN_EMAIL" \
        '{user_email: $email, user_role: "proxy_admin"}')"
    post_json "/user/new" "$create_payload"
fi

echo "Setting password for '${LITELLM_ADMIN_EMAIL}'..."
post_json "/user/update" "$password_payload"

login_http="$(login_code)"
if [ "$login_http" != "303" ]; then
    echo "Error: login verification returned HTTP ${login_http}." >&2
    exit 1
fi

echo "=========================================================="
echo "Admin account '${LITELLM_ADMIN_EMAIL}' can sign in."
echo "The first UI sign-in must choose a new password. LiteLLM flags passwords set by the admin API."
echo "Web UI: http://localhost:${LITELLM_PORT}/ui"
echo "=========================================================="
