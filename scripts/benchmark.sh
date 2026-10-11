#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=load_env.sh
source "$SCRIPT_DIR/load_env.sh"
load_env_file "$PROJECT_DIR/.env"

require_positive_int() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: ${name} must be a positive integer." >&2
        exit 1
    fi
}

PROMPTS="${1:-10}"
INPUT_LEN="${2:-512}"
OUTPUT_LEN="${3:-128}"
MODEL="${VLLM_MODEL:-Qwen/Qwen3.8-27B-FP8}"

require_positive_int PROMPTS "$PROMPTS"
require_positive_int INPUT_LEN "$INPUT_LEN"
require_positive_int OUTPUT_LEN "$OUTPUT_LEN"

echo "=========================================================="
echo "Running vLLM Benchmark (${PROMPTS} prompts, input: ${INPUT_LEN}, output: ${OUTPUT_LEN}, model: ${MODEL})"
echo "=========================================================="

docker exec vllm vllm bench serve \
  --num-prompts "${PROMPTS}" \
  --dataset-name random \
  --random-input-len "${INPUT_LEN}" \
  --random-output-len "${OUTPUT_LEN}" \
  --model "${MODEL}" \
  --base-url http://127.0.0.1:8000
