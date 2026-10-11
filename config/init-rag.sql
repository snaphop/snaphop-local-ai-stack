-- ==============================================================================
-- PostgreSQL 18 + pgvector RAG Initialization Schema
-- ==============================================================================

-- Enable pgvector extension for dense vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable pgcrypto for UUID generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Documents catalog table (parent documents, files, web pages)
CREATE TABLE IF NOT EXISTS rag_documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    source TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Chunks table with vector embeddings (default dimension 1536, compatible with OpenAI & standard embeddings)
CREATE TABLE IF NOT EXISTS rag_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID REFERENCES rag_documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- HNSW Index for fast approximate cosine similarity search
CREATE INDEX IF NOT EXISTS rag_chunks_embedding_hnsw_idx
ON rag_chunks
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- GIN index used when match_rag_chunks is given query_text.
CREATE INDEX IF NOT EXISTS rag_chunks_content_tsv_idx
ON rag_chunks
USING gin (to_tsvector('english', content));

-- Cosine search. query_text adds English full-text rank from the GIN index.
-- Replacing the argument list requires dropping the previous signature.
DROP FUNCTION IF EXISTS match_rag_chunks(vector, float, int);
DROP FUNCTION IF EXISTS match_rag_chunks(vector, float, int, text);
CREATE FUNCTION match_rag_chunks(
    query_embedding vector(1536),
    match_threshold float DEFAULT 0.5,
    match_count int DEFAULT 5,
    query_text text DEFAULT NULL
)
RETURNS TABLE (
    id UUID,
    document_id UUID,
    content TEXT,
    metadata JSONB,
    similarity float
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF query_text IS NULL OR btrim(query_text) = '' THEN
        RETURN QUERY
        SELECT ranked.id, ranked.document_id, ranked.content, ranked.metadata, ranked.score
        FROM (
            SELECT
                c.id,
                c.document_id,
                c.content,
                c.metadata,
                (1 - (c.embedding <=> query_embedding))::double precision AS score
            FROM rag_chunks AS c
            WHERE 1 - (c.embedding <=> query_embedding) > match_threshold
            ORDER BY c.embedding <=> query_embedding
            LIMIT match_count
        ) AS ranked;
    ELSE
        RETURN QUERY
        SELECT ranked.id, ranked.document_id, ranked.content, ranked.metadata, ranked.score
        FROM (
            SELECT
                c.id,
                c.document_id,
                c.content,
                c.metadata,
                (
                    (1 - (c.embedding <=> query_embedding))
                    + ts_rank(
                        to_tsvector('english', c.content),
                        websearch_to_tsquery('english', query_text)
                    )
                )::double precision AS score
            FROM rag_chunks AS c
            WHERE 1 - (c.embedding <=> query_embedding) > match_threshold
               OR to_tsvector('english', c.content) @@ websearch_to_tsquery('english', query_text)
            ORDER BY score DESC
            LIMIT match_count
        ) AS ranked;
    END IF;
END;
$$;
