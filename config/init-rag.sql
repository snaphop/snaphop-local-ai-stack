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

-- Full-text GIN index for hybrid lexical + semantic search
CREATE INDEX IF NOT EXISTS rag_chunks_content_tsv_idx 
ON rag_chunks 
USING gin (to_tsvector('english', content));

-- Helper function for hybrid RAG search (vector similarity + full-text rank)
CREATE OR REPLACE FUNCTION match_rag_chunks(
    query_embedding vector(1536),
    match_threshold float DEFAULT 0.5,
    match_count int DEFAULT 5
)
RETURNS TABLE (
    id UUID,
    document_id UUID,
    content TEXT,
    metadata JSONB,
    similarity float
)
LANGUAGE sql STABLE
AS $$
    SELECT
        id,
        document_id,
        content,
        metadata,
        1 - (rag_chunks.embedding <=> query_embedding) AS similarity
    FROM rag_chunks
    WHERE 1 - (rag_chunks.embedding <=> query_embedding) > match_threshold
    ORDER BY similarity DESC
    LIMIT match_count;
$$;
