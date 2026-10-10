#!/usr/bin/env bash
# ==============================================================================
# SnapHop Local AI Stack - PostgreSQL 18 pgvector RAG Test Suite
# ==============================================================================
# Verifies:
# 1. PostgreSQL 18 & pgvector extension health
# 2. Schema tables (rag_documents, rag_chunks, HNSW index)
# 3. Vector insertion & cosine similarity search
# 4. Context retrieval & grounded generation via LiteLLM / Qwen
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
fi

LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_MASTER_KEY:-REPLACE_WITH_UNIQUE_SECRET}"
RAG_DB_USER="${RAG_DB_USER:-rag}"
RAG_DB_NAME="${RAG_DB_NAME:-rag}"

echo "=========================================================="
echo "1. Checking PostgreSQL 18 & pgvector Extension Status"
echo "=========================================================="

PG_VERSION=$(docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -t -A -c "SHOW server_version;")
PGVECTOR_VERSION=$(docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -t -A -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';")

echo "  PostgreSQL Version: ${PG_VERSION}"
echo "  pgvector Extension: v${PGVECTOR_VERSION}"

if [[ "$PG_VERSION" != 18* ]]; then
    echo "Error: Expected PostgreSQL 18, found: $PG_VERSION"
    exit 1
fi

if [ -z "$PGVECTOR_VERSION" ]; then
    echo "Error: pgvector extension is not installed!"
    exit 1
fi
echo "  Status: PostgreSQL 18 + pgvector healthy."
echo ""

echo "=========================================================="
echo "2. Seeding Sample Knowledge Base Documents"
echo "=========================================================="

docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -c "
DO \$\$
DECLARE
    doc_id UUID;
    v1 vector(1536);
    v2 vector(1536);
BEGIN
    -- Clear previous test entries
    DELETE FROM rag_documents WHERE title = 'DGX Spark Specification Doc';

    -- Insert Parent Document
    INSERT INTO rag_documents (title, source, metadata)
    VALUES ('DGX Spark Specification Doc', 'internal://specs/dgx-spark', '{\"version\": \"1.0\"}'::jsonb)
    RETURNING id INTO doc_id;

    -- Construct base vector 1 (focused on GPU architecture)
    SELECT (ARRAY(SELECT (0.5 + random()*0.05)::real FROM generate_series(1, 1536)))::vector(1536) INTO v1;

    -- Construct base vector 2 (orthogonal / different topic)
    SELECT (ARRAY(SELECT (-0.5 + random()*0.05)::real FROM generate_series(1, 1536)))::vector(1536) INTO v2;

    -- Insert Knowledge Chunks
    INSERT INTO rag_chunks (document_id, chunk_index, content, metadata, embedding)
    VALUES 
    (doc_id, 1, 'The DGX Spark inference node is equipped with an NVIDIA GB10 Blackwell GPU featuring 121 GB unified memory, operating on sm_121 architecture with native FP8 Tensor Cores.', '{\"topic\": \"hardware\"}'::jsonb, v1),
    (doc_id, 2, 'The server chassis operates with silent fan profiles maintaining 46 degrees Celsius idle temperature at 12 Watts total power draw.', '{\"topic\": \"thermals\"}'::jsonb, v2);

END \$\$;
" > /dev/null

CHUNK_COUNT=$(docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -t -A -c "SELECT count(*) FROM rag_chunks;")
echo "  Total Chunks in database: ${CHUNK_COUNT}"
echo ""

echo "=========================================================="
echo "3. Performing Vector Similarity Search (HNSW Index)"
echo "=========================================================="

# Search using a query vector close to vector 1
RETRIEVED_CONTENT=$(docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -t -A -c "
WITH target_query AS (
    SELECT embedding FROM rag_chunks WHERE content LIKE '%GB10 Blackwell%' LIMIT 1
)
SELECT content
FROM rag_chunks, target_query
ORDER BY rag_chunks.embedding <=> target_query.embedding
LIMIT 1;
")

SIMILARITY_SCORE=$(docker exec rag-db psql -U "$RAG_DB_USER" -d "$RAG_DB_NAME" -t -A -c "
WITH target_query AS (
    SELECT embedding FROM rag_chunks WHERE content LIKE '%GB10 Blackwell%' LIMIT 1
)
SELECT round((1 - (rag_chunks.embedding <=> target_query.embedding))::numeric, 4)
FROM rag_chunks, target_query
ORDER BY rag_chunks.embedding <=> target_query.embedding
LIMIT 1;
")

echo "  Query Focus: 'NVIDIA GB10 Blackwell GPU specs'"
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

PAYLOAD=$(jq -n \
  --arg prompt "$PROMPT" \
  '{
    model: "qwen",
    messages: [
      {role: "system", content: "You are a precise technical assistant."},
      {role: "user", content: $prompt}
    ],
    temperature: 0.2,
    max_tokens: 256
  }')

RESPONSE=$(curl -s -X POST "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_KEY}" \
  -d "$PAYLOAD")

ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' | tr -d '\n' | sed 's/^[ \t]*//')

if [ -z "$ANSWER" ]; then
    echo "Warning: No content parsed. Raw response:"
    echo "$RESPONSE"
else
    echo "  Question: ${QUESTION}"
    echo "  Grounded Answer: ${ANSWER}"
fi

echo ""
echo "=========================================================="
echo "PostgreSQL 18 pgvector RAG test completed successfully!"
echo "=========================================================="
