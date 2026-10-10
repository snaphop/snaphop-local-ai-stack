#!/usr/bin/env bash
set -euo pipefail

# Load environment variables if .env exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/.env"
  set +a
fi

PORT="${LITELLM_PORT:-4000}"
KEY="${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"

echo "=========================================================="
echo "Testing SnapHop Local AI Stack on port ${PORT}"
echo "=========================================================="

echo -e "\n1. Checking models endpoint..."
curl -s -H "Authorization: Bearer ${KEY}" "http://127.0.0.1:${PORT}/v1/models" | jq .

echo -e "\n2. Testing chat completion (Qwen 3.8 27B FP8)..."
curl -s -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${KEY}" \
  -d '{
    "model": "qwen",
    "messages": [
      {"role": "user", "content": "What is the capital of France? Reply in one short sentence."}
    ],
    "temperature": 0.7,
    "max_tokens": 150
  }' | jq .

echo -e "\n3. Testing Anthropic Messages protocol..."
curl -s -X POST "http://127.0.0.1:${PORT}/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "qwen",
    "max_tokens": 100,
    "messages": [
      {"role": "user", "content": "Say hello!"}
    ]
  }' | jq .

echo -e "\nAll tests completed successfully!"
