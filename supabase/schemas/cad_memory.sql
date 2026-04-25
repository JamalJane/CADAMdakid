-- =============================================================================
-- CAD trace memory — Parts 1–4 (schema reference)
-- =============================================================================
-- This file is the CANONICAL REFERENCE definition. It is NOT applied directly.
-- See: supabase/migrations/20260424220000_cad_memory_part1.sql and
--      supabase/migrations/20260424230000_cad_memory_parts_2_3_4.sql
--      for runnable migrations.
--
-- Concepts (from docs/glossary-cad-vector-memory.md Part 1):
--   Trace          — one end-to-end or partial recorded run toward a user goal
--   Step/subgoal   — bounded milestone inside a trace; unit of embed/score/retrieve
--   Candidate      — a completed (or partial) trace that might replace the incumbent
--   Eligible trace — a candidate that passed all required gates
--   Incumbent      — current winning stored solution for a retrieval key
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extension
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

-- Lifecycle of a trace.
CREATE TYPE "public"."trace_status" AS ENUM (
    'running',      -- in progress; raw metrics accumulating
    'completed',    -- finished normally; steps may be promoted
    'abandoned'     -- cancelled or errored before meaningful output
);

-- Result of deterministic compile checks on a step's FeatureScript.
-- 'uncertain' means heuristics could not decide — requires LLM judge or human review.
CREATE TYPE "public"."step_compile_result" AS ENUM (
    'success',
    'failure',
    'uncertain'
);

-- Result of the LLM judge pass on a step's FeatureScript.
CREATE TYPE "public"."step_judge_outcome" AS ENUM (
    'pass',
    'fail',
    'uncertain'
);

-- Gate result for a candidate step.
-- 'pending'   — gates have not yet run
-- 'eligible'  — all required gates passed; step may compete for incumbent
-- 'ineligible'— at least one required gate failed; step cannot win incumbent
CREATE TYPE "public"."step_eligibility_status" AS ENUM (
    'pending',
    'eligible',
    'ineligible'
);

-- Lifecycle of an incumbent record.
-- Only one 'active' row per (user_id, retrieval_key) is enforced by a
-- partial unique index.
CREATE TYPE "public"."incumbent_status" AS ENUM (
    'active',   -- current winner for this retrieval key
    'retired'   -- superseded by a newer challenger
);

-- ---------------------------------------------------------------------------
-- cad_traces
-- ---------------------------------------------------------------------------
-- One row per recorded run. Stores prompt-level metadata and raw aggregates.
-- Steps (cad_steps) hang off traces.

CREATE TABLE "public"."cad_traces" (
    "id"              uuid        NOT NULL DEFAULT gen_random_uuid(),
    "user_id"         uuid        NOT NULL,
    -- nullable: headless / API sessions may not have a conversation row
    "conversation_id" uuid,
    "status"          public.trace_status NOT NULL DEFAULT 'running',
    -- Free-text goal the user expressed at trace start; used for title generation
    -- and as a fallback embedding source when steps have not yet been normalised.
    "goal_text"       text,
    -- OpenRouter / model identifier used for this run (e.g. "anthropic/claude-sonnet-4-5")
    "model_id"        text,
    -- Raw metrics — source-of-truth numbers that scoring is derived from
    "raw_token_count" integer     NOT NULL DEFAULT 0,
    "turn_count"      integer     NOT NULL DEFAULT 0,
    "started_at"      timestamptz NOT NULL DEFAULT now(),
    "completed_at"    timestamptz,
    -- Arbitrary versioned JSON for future raw metrics (latency, cost, etc.)
    -- Schema: { "latency_ms"?: number, "cost_usd"?: number, ... }
    "metadata"        jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT "cad_traces_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_traces" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_traces"
    ADD CONSTRAINT "cad_traces_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE "public"."cad_traces"
    ADD CONSTRAINT "cad_traces_conversation_id_fkey"
        FOREIGN KEY ("conversation_id") REFERENCES public.conversations("id")
        ON UPDATE CASCADE ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- cad_steps
-- ---------------------------------------------------------------------------
-- One row per bounded milestone (subgoal) within a trace. This is the grain
-- that gets embedded, scored, and retrieved. A single trace produces 1–N steps.

CREATE TABLE "public"."cad_steps" (
    "id"                  uuid        NOT NULL DEFAULT gen_random_uuid(),
    "trace_id"            uuid        NOT NULL,
    "user_id"             uuid        NOT NULL,
    -- Human-readable subgoal text as emitted by the agent / user request
    "subgoal_text"        text        NOT NULL,
    -- Normalised form used as the retrieval key seed (lowercased, stripped punctuation, etc.)
    -- Populated by application code before embedding.
    "subgoal_normalized"  text,
    -- SHA-256 hex digest of featurescript_code; used for dedup and audit
    "featurescript_hash"  text,
    -- Inline FeatureScript (OpenSCAD) code produced for this step.
    -- Stored inline for v1; migrate to Storage pointer if scripts exceed ~1 MB.
    "featurescript_code"  text,
    -- Raw metrics for this step
    "token_count"         integer     NOT NULL DEFAULT 0,
    "turn_count"          integer     NOT NULL DEFAULT 0,
    "latency_ms"          integer,
    -- Gate results (Part 3 populates these)
    "compile_result"      public.step_compile_result     NOT NULL DEFAULT 'uncertain',
    "judge_outcome"       public.step_judge_outcome,
    "confidence_score"    double precision,
    "eligibility_status"  public.step_eligibility_status NOT NULL DEFAULT 'pending',
    -- Tag vocabulary: e.g. {'primitive:box', 'op:fillet', 'pattern:linear'}
    -- text[] for v1; GIN-indexed for tag-overlap retrieval.
    "tags"                text[]      NOT NULL DEFAULT '{}',
    -- Position of this step within the trace (0-indexed)
    "step_index"          integer     NOT NULL DEFAULT 0,
    "created_at"          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT "cad_steps_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_steps" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_steps"
    ADD CONSTRAINT "cad_steps_trace_id_fkey"
        FOREIGN KEY ("trace_id") REFERENCES public.cad_traces("id")
        ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE "public"."cad_steps"
    ADD CONSTRAINT "cad_steps_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE;

-- ---------------------------------------------------------------------------
-- cad_incumbents
-- ---------------------------------------------------------------------------
-- Tracks the winning stored solution (incumbent) for a given retrieval key,
-- per user (v1). Globalisation is planned for a later migration.
--
-- Invariant: at most ONE row with status = 'active' per (user_id, retrieval_key).
-- Enforced by a partial unique index below.

CREATE TABLE "public"."cad_incumbents" (
    "id"                   uuid        NOT NULL DEFAULT gen_random_uuid(),
    -- Deterministic key: SHA-256 of (subgoal_normalized || '|' || sorted_tags)
    -- Application code computes this before upserting.
    "retrieval_key"        text        NOT NULL,
    -- The step that currently (or previously) holds this slot
    "step_id"              uuid,
    "user_id"              uuid        NOT NULL,
    "status"               public.incumbent_status NOT NULL DEFAULT 'active',
    -- Composite score computed with balanced write weights at promotion time.
    -- Higher = better (convention fixed project-wide).
    "write_score"          double precision,
    "promoted_at"          timestamptz NOT NULL DEFAULT now(),
    -- Populated when this incumbent is superseded
    "replaced_at"          timestamptz,
    -- Points to the step that replaced this row (for audit trail)
    "replacement_step_id"  uuid,
    -- Embedding model used for the vector
    "embedding_model_id"   text,
    -- Dense vector representing the normalized subgoal + tags
    "embedding"            vector(1536),
    -- Arbitrary versioned JSON for future incumbent metadata
    -- Schema: { "write_weights"?: object, "judge_outcome"?: string, ... }
    "metadata"             jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT "cad_incumbents_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_incumbents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_step_id_fkey"
        FOREIGN KEY ("step_id") REFERENCES public.cad_steps("id")
        ON DELETE SET NULL;

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_replacement_step_id_fkey"
        FOREIGN KEY ("replacement_step_id") REFERENCES public.cad_steps("id")
        ON DELETE SET NULL;

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE;

-- Enforce one active incumbent per (user, retrieval_key)
CREATE UNIQUE INDEX "cad_incumbents_active_per_user_key"
    ON public.cad_incumbents ("user_id", "retrieval_key")
    WHERE status = 'active';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- cad_steps — query patterns
CREATE INDEX "idx_cad_steps_trace_id"          ON public.cad_steps ("trace_id");
CREATE INDEX "idx_cad_steps_user_id"            ON public.cad_steps ("user_id");
CREATE INDEX "idx_cad_steps_subgoal_normalized" ON public.cad_steps ("subgoal_normalized");
CREATE INDEX "idx_cad_steps_eligibility"        ON public.cad_steps ("eligibility_status");
CREATE INDEX "idx_cad_steps_compile_result"     ON public.cad_steps ("compile_result");
CREATE INDEX "idx_cad_steps_tags"               ON public.cad_steps USING GIN ("tags");

-- cad_traces — query patterns
CREATE INDEX "idx_cad_traces_user_id"           ON public.cad_traces ("user_id");
CREATE INDEX "idx_cad_traces_conversation_id"   ON public.cad_traces ("conversation_id");
CREATE INDEX "idx_cad_traces_status"            ON public.cad_traces ("status");

-- cad_incumbents — query patterns
CREATE INDEX "idx_cad_incumbents_user_id"       ON public.cad_incumbents ("user_id");
CREATE INDEX "idx_cad_incumbents_step_id"       ON public.cad_incumbents ("step_id");
CREATE INDEX "idx_cad_incumbents_retrieval_key" ON public.cad_incumbents ("retrieval_key");
CREATE INDEX "idx_cad_incumbents_embedding_hnsw" ON public.cad_incumbents USING hnsw ("embedding" vector_cosine_ops);

-- ---------------------------------------------------------------------------
-- RPC Functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "public"."match_cad_incumbents"(
    "p_user_id" uuid,
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
SET search_path TO 'public'
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
    WHERE i.user_id = p_user_id
      AND i.status = 'active'
      AND i.embedding IS NOT NULL
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

COMMENT ON FUNCTION "public"."match_cad_incumbents"(uuid, vector(1536), integer, text[]) IS
    'ANN candidate pool for one user; required p_user_id for service_role safety. filter_tags: OR (overlap).';

GRANT EXECUTE ON FUNCTION "public"."match_cad_incumbents"(uuid, vector(1536), integer, text[])
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RLS Policies
-- ---------------------------------------------------------------------------

-- cad_traces: users manage their own rows
CREATE POLICY "Users manage their own traces"
    ON public.cad_traces
    AS PERMISSIVE FOR ALL
    TO authenticated
    USING  ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

-- cad_steps: users manage their own rows
CREATE POLICY "Users manage their own steps"
    ON public.cad_steps
    AS PERMISSIVE FOR ALL
    TO authenticated
    USING  ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

-- cad_incumbents: users can read their own rows; only service_role may write.
-- Incumbents are promoted by the system (edge function), not the client directly.
CREATE POLICY "Users read their own incumbents"
    ON public.cad_incumbents
    AS PERMISSIVE FOR SELECT
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Service role manages incumbents"
    ON public.cad_incumbents
    AS PERMISSIVE FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
