#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=load_env.sh
source "${SCRIPT_DIR}/load_env.sh"
load_env_file "${PROJECT_DIR}/.env"

PORT="${LITELLM_PORT:-4000}"
KEY="${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"

expect_json() {
    local name="$1"
    local filter="$2"
    shift 2
    local body_file http_code
    body_file="$(mktemp)"
    http_code="$(curl -sS -o "$body_file" -w '%{http_code}' "$@")" || {
        rm -f "$body_file"
        echo "Error: ${name} request failed." >&2
        exit 1
    }
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Error: ${name} returned HTTP ${http_code}." >&2
        cat "$body_file" >&2
        rm -f "$body_file"
        exit 1
    fi
    if ! jq -e "$filter" "$body_file" >/dev/null; then
        echo "Error: ${name} response did not contain the expected payload." >&2
        cat "$body_file" >&2
        rm -f "$body_file"
        exit 1
    fi
    jq . "$body_file"
    rm -f "$body_file"
}

echo "=========================================================="
echo "Testing SnapHop Local AI Stack on port ${PORT}"
echo "=========================================================="

echo -e "\n1. Checking models endpoint..."
expect_json "models" '.data | type == "array" and length > 0' \
    -H "Authorization: Bearer ${KEY}" \
    "http://127.0.0.1:${PORT}/v1/models"

echo -e "\n2. Testing chat completion..."
expect_json "chat completion" '.choices[0].message.content | type == "string" and length > 0' \
    -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${KEY}" \
    --json @- <<'JSON'
{
  "model": "qwen",
  "messages": [
    {"role": "user", "content": "What is the capital of France? Reply in one short sentence."}
  ],
  "temperature": 0.7,
  "max_tokens": 150
}
JSON

echo -e "\n3. Testing Anthropic Messages protocol..."
expect_json "anthropic messages" '(.content[0].text // .choices[0].message.content // "") | type == "string" and length > 0' \
    -X POST "http://127.0.0.1:${PORT}/v1/messages" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${KEY}" \
    -H "anthropic-version: 2023-06-01" \
    --json @- <<'JSON'
{
  "model": "qwen",
  "max_tokens": 100,
  "messages": [
    {"role": "user", "content": "Say hello!"}
  ]
}
JSON

echo -e "\nAll tests completed successfully!"
