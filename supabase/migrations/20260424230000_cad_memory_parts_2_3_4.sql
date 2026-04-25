-- =============================================================================
-- Migration: CAD trace memory — Parts 2, 3 & 4
-- Timestamp: 20260424230000
-- Glossary ref: docs/glossary-cad-vector-memory.md
--
-- Creates:
--   Extension: pgvector
--   Enums:     step_judge_outcome
--   Columns:   cad_steps: judge_outcome, confidence_score
--              cad_incumbents: embedding_model_id, embedding
--   Indexes:   HNSW on cad_incumbents.embedding
--   Functions: match_cad_incumbents
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extension
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE "public"."step_judge_outcome" AS ENUM (
        'pass',
        'fail',
        'uncertain'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- Table Updates
-- ---------------------------------------------------------------------------

ALTER TABLE "public"."cad_steps"
    ADD COLUMN IF NOT EXISTS "judge_outcome" public.step_judge_outcome,
    ADD COLUMN IF NOT EXISTS "confidence_score" double precision;

ALTER TABLE "public"."cad_incumbents"
    ADD COLUMN IF NOT EXISTS "embedding_model_id" text,
    ADD COLUMN IF NOT EXISTS "embedding" vector(1536);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- HNSW index for fast ANN retrieval using cosine distance
CREATE INDEX IF NOT EXISTS "idx_cad_incumbents_embedding_hnsw"
    ON public.cad_incumbents
    USING hnsw ("embedding" vector_cosine_ops);

-- ---------------------------------------------------------------------------
-- RPC Functions
-- ---------------------------------------------------------------------------

-- match_cad_incumbents
-- Retrieves top candidates for a given query embedding, applying optional tag filters.
-- Returns the raw candidate pool. Application layer (Edge Function) is responsible
-- for computing composite scores using session weights.
CREATE OR REPLACE FUNCTION "public"."match_cad_incumbents"(
    "query_embedding" vector(1536),
    "match_count" integer DEFAULT 10,
    "filter_tags" text[] DEFAULT NULL
)
RETURNS TABLE (
    "id" uuid,
    "retrieval_key" text,
    "step_id" uuid,
    "user_id" uuid,
    "status" public.incumbent_status,
    "write_score" double precision,
    "promoted_at" timestamptz,
    "replaced_at" timestamptz,
    "replacement_step_id" uuid,
    "metadata" jsonb,
    "embedding_model_id" text,
    "embedding" vector(1536),
    "similarity" double precision
)
LANGUAGE "plpgsql"
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        i.id,
        i.retrieval_key,
        i.step_id,
        i.user_id,
        i.status,
        i.write_score,
        i.promoted_at,
        i.replaced_at,
        i.replacement_step_id,
        i.metadata,
        i.embedding_model_id,
        i.embedding,
        1 - (i.embedding <=> query_embedding) AS similarity
    FROM public.cad_incumbents i
    -- Ensure we only match active incumbents. 
    -- If exploration allows retired ones, this filter can be relaxed or parameterized.
    WHERE i.status = 'active'
      -- Apply tag filtering via the associated step if filter_tags is provided
      AND (
          filter_tags IS NULL
          OR EXISTS (
              SELECT 1 FROM public.cad_steps s 
              WHERE s.id = i.step_id 
              AND s.tags && filter_tags
          )
      )
    ORDER BY i.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;
