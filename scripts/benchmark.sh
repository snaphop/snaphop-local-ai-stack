#!/usr/bin/env bash
set -euo pipefail

PROMPTS="${1:-10}"
INPUT_LEN="${2:-512}"
OUTPUT_LEN="${3:-128}"

echo "=========================================================="
echo "Running vLLM Benchmark (${PROMPTS} prompts, input: ${INPUT_LEN}, output: ${OUTPUT_LEN})"
echo "=========================================================="

docker exec vllm vllm bench serve \
  --num-prompts "${PROMPTS}" \
  --dataset-name random \
  --random-input-len "${INPUT_LEN}" \
  --random-output-len "${OUTPUT_LEN}" \
  --model Qwen/Qwen3.8-27B-FP8 \
  --base-url http://127.0.0.1:8000
