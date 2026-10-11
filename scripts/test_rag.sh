#!/usr/bin/env bash
# Verify pgvector health, an independent match_rag_chunks query, and a grounded answer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=load_env.sh
source "$SCRIPT_DIR/load_env.sh"
load_env_file "$PROJECT_DIR/.env"

LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"
RAG_DB_USER="${RAG_DB_USER:-rag}"
RAG_DB_NAME="${RAG_DB_NAME:-rag}"

rag_psql() {
    docker exec -i rag-db psql -v ON_ERROR_STOP=1 -U "$RAG_DB_USER" -d "$RAG_DB_NAME" "$@"
}

echo "=========================================================="
echo "1. Checking PostgreSQL 18 & pgvector Extension Status"
echo "=========================================================="

PG_VERSION="$(rag_psql -t -A -c "SHOW server_version;")"
PGVECTOR_VERSION="$(rag_psql -t -A -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';")"

echo "  PostgreSQL Version: ${PG_VERSION}"
echo "  pgvector Extension: v${PGVECTOR_VERSION}"

if [[ "$PG_VERSION" != 18* ]]; then
    echo "Error: Expected PostgreSQL 18, found: $PG_VERSION" >&2
    exit 1
fi

if [ -z "$PGVECTOR_VERSION" ]; then
    echo "Error: pgvector extension is not installed." >&2
    exit 1
fi
echo "  Status: PostgreSQL 18 + pgvector healthy."
echo ""

echo "=========================================================="
echo "2. Seeding Sample Knowledge Base Documents"
echo "=========================================================="

rag_psql -q <<'SQL'
DO $$
DECLARE
    doc_id UUID;
    hardware vector(1536);
    thermals vector(1536);
BEGIN
    DELETE FROM rag_documents WHERE title = 'DGX Spark Specification Doc';

    INSERT INTO rag_documents (title, source, metadata)
    VALUES ('DGX Spark Specification Doc', 'internal://specs/dgx-spark', '{"version": "1.0"}'::jsonb)
    RETURNING id INTO doc_id;

    SELECT (ARRAY(SELECT 0.5::real FROM generate_series(1, 1536)))::vector(1536) INTO hardware;
    SELECT (ARRAY(SELECT -0.5::real FROM generate_series(1, 1536)))::vector(1536) INTO thermals;

    INSERT INTO rag_chunks (document_id, chunk_index, content, metadata, embedding)
    VALUES
    (doc_id, 1, 'The DGX Spark inference node is equipped with an NVIDIA GB10 Blackwell GPU featuring 121 GB unified memory, operating on sm_121 architecture with native FP8 Tensor Cores.', '{"topic": "hardware"}'::jsonb, hardware),
    (doc_id, 2, 'The server chassis operates with silent fan profiles maintaining 46 degrees Celsius idle temperature at 12 Watts total power draw.', '{"topic": "thermals"}'::jsonb, thermals);
END $$;
SQL

CHUNK_COUNT="$(rag_psql -t -A -c "SELECT count(*) FROM rag_chunks WHERE content LIKE '%GB10 Blackwell%';")"
if [ "${CHUNK_COUNT:-0}" -lt 1 ]; then
    echo "Error: RAG seed did not store the hardware chunk." >&2
    exit 1
fi
echo "  Hardware chunks stored: ${CHUNK_COUNT}"
echo ""

echo "=========================================================="
echo "3. Performing Vector Similarity Search (HNSW Index)"
echo "=========================================================="

HNSW_INDEX="$(rag_psql -t -A -c "SELECT indexname FROM pg_indexes WHERE indexname = 'rag_chunks_embedding_hnsw_idx';")"
if [ "$HNSW_INDEX" != "rag_chunks_embedding_hnsw_idx" ]; then
    echo "Error: HNSW index rag_chunks_embedding_hnsw_idx is missing." >&2
    exit 1
fi

# Query is close to the hardware embedding and is not that stored vector.
VECTOR_RESULT="$(rag_psql -t -A -c "
SELECT content || chr(31) || similarity::text
FROM match_rag_chunks(
    (ARRAY[0::real] || ARRAY(SELECT 0.5::real FROM generate_series(1, 1535)))::vector(1536),
    0.5,
    1
);
")"
RETRIEVED_CONTENT="${VECTOR_RESULT%%$'\x1f'*}"
SIMILARITY_SCORE="${VECTOR_RESULT#*$'\x1f'}"

if [[ "$RETRIEVED_CONTENT" != *GB10\ Blackwell* ]]; then
    echo "Error: match_rag_chunks did not return the hardware chunk." >&2
    echo "  Got: ${RETRIEVED_CONTENT}" >&2
    exit 1
fi
if ! awk -v score="$SIMILARITY_SCORE" 'BEGIN { exit !(score > 0.9 && score < 1) }'; then
    echo "Error: expected an independent cosine score in (0.9, 1), got ${SIMILARITY_SCORE}." >&2
    exit 1
fi

HYBRID_CONTENT="$(rag_psql -t -A -c "
SELECT content
FROM match_rag_chunks(
    (ARRAY[0::real] || ARRAY(SELECT 0.5::real FROM generate_series(1, 1535)))::vector(1536),
    0.5,
    1,
    'GB10 Blackwell'
);
")"
if [[ "$HYBRID_CONTENT" != *GB10\ Blackwell* ]]; then
    echo "Error: hybrid match_rag_chunks did not return the hardware chunk." >&2
    exit 1
fi

echo "  Query Focus: NVIDIA GB10 Blackwell GPU specs"
echo "  Cosine Similarity Score: ${SIMILARITY_SCORE}"
echo "  Retrieved Context Chunk:"
echo "    \"${RETRIEVED_CONTENT}\""
echo ""

echo "=========================================================="
echo "4. Executing Grounded RAG Query via LiteLLM Gateway"
echo "=========================================================="

QUESTION="What GPU model and unified memory capacity does the DGX Spark node use? Answer concisely in one sentence."
PROMPT="You are a factual AI assistant. Answer the user question based strictly on the retrieved context below.

Context:
${RETRIEVED_CONTENT}

Question: ${QUESTION}"

PAYLOAD="$(jq -n \
  --arg prompt "$PROMPT" \
  '{
    model: "qwen",
    messages: [
      {role: "system", content: "You are a precise technical assistant."},
      {role: "user", content: $prompt}
    ],
    temperature: 0.2,
    max_tokens: 256
  }')"

response_body="$(mktemp)"
http_code="$(curl -sS -o "$response_body" -w '%{http_code}' \
  -X POST "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  --data-binary @- <<<"$PAYLOAD")" || {
    rm -f "$response_body"
    echo "Error: chat completion request failed." >&2
    exit 1
}
if [ "$http_code" != "200" ]; then
    echo "Error: chat completion returned HTTP ${http_code}." >&2
    cat "$response_body" >&2
    rm -f "$response_body"
    exit 1
fi
ANSWER="$(jq -r '.choices[0].message.content // empty' "$response_body" | tr -d '\n' | sed 's/^[ \t]*//')"
if [ -z "$ANSWER" ]; then
    echo "Error: chat completion returned no content." >&2
    cat "$response_body" >&2
    rm -f "$response_body"
    exit 1
fi
rm -f "$response_body"

echo "  Question: ${QUESTION}"
echo "  Grounded Answer: ${ANSWER}"
echo ""
echo "=========================================================="
echo "PostgreSQL 18 pgvector RAG test completed successfully!"
echo "=========================================================="
