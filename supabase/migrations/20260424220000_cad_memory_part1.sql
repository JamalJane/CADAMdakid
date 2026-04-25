-- =============================================================================
-- Migration: CAD trace memory — Part 1 (Execution units & library roles)
-- Timestamp: 20260424220000
-- Glossary ref: docs/glossary-cad-vector-memory.md §Part 1 of 4
--
-- Creates:
--   Enums:  trace_status | step_compile_result | step_eligibility_status | incumbent_status
--   Tables: cad_traces | cad_steps | cad_incumbents
--   Indexes, FK constraints, and RLS policies for all three tables.
--
-- Later parts will add:
--   Part 2 — scoring columns, write_weights, composite_score helpers
--   Part 3 — gate functions, judge outcome columns
--   Part 4 — vector (pgvector) columns, embedding pipeline
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

DO $$ BEGIN
    CREATE TYPE "public"."trace_status" AS ENUM (
        'running',
        'completed',
        'abandoned'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."step_compile_result" AS ENUM (
        'success',
        'failure',
        'uncertain'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."step_eligibility_status" AS ENUM (
        'pending',
        'eligible',
        'ineligible'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE "public"."incumbent_status" AS ENUM (
        'active',
        'retired'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- cad_traces
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."cad_traces" (
    "id"              uuid        NOT NULL DEFAULT gen_random_uuid(),
    "user_id"         uuid        NOT NULL,
    "conversation_id" uuid,
    "status"          public.trace_status NOT NULL DEFAULT 'running',
    "goal_text"       text,
    "model_id"        text,
    "raw_token_count" integer     NOT NULL DEFAULT 0,
    "turn_count"      integer     NOT NULL DEFAULT 0,
    "started_at"      timestamptz NOT NULL DEFAULT now(),
    "completed_at"    timestamptz,
    "metadata"        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT "cad_traces_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_traces" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_traces"
    ADD CONSTRAINT "cad_traces_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."cad_traces"
    VALIDATE CONSTRAINT "cad_traces_user_id_fkey";

ALTER TABLE "public"."cad_traces"
    ADD CONSTRAINT "cad_traces_conversation_id_fkey"
        FOREIGN KEY ("conversation_id") REFERENCES public.conversations("id")
        ON UPDATE CASCADE ON DELETE SET NULL NOT VALID;

ALTER TABLE "public"."cad_traces"
    VALIDATE CONSTRAINT "cad_traces_conversation_id_fkey";

-- ---------------------------------------------------------------------------
-- cad_steps
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."cad_steps" (
    "id"                  uuid        NOT NULL DEFAULT gen_random_uuid(),
    "trace_id"            uuid        NOT NULL,
    "user_id"             uuid        NOT NULL,
    "subgoal_text"        text        NOT NULL,
    "subgoal_normalized"  text,
    "featurescript_hash"  text,
    "featurescript_code"  text,
    "token_count"         integer     NOT NULL DEFAULT 0,
    "turn_count"          integer     NOT NULL DEFAULT 0,
    "latency_ms"          integer,
    "compile_result"      public.step_compile_result     NOT NULL DEFAULT 'uncertain',
    "eligibility_status"  public.step_eligibility_status NOT NULL DEFAULT 'pending',
    "tags"                text[]      NOT NULL DEFAULT '{}',
    "step_index"          integer     NOT NULL DEFAULT 0,
    "created_at"          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT "cad_steps_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_steps" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_steps"
    ADD CONSTRAINT "cad_steps_trace_id_fkey"
        FOREIGN KEY ("trace_id") REFERENCES public.cad_traces("id")
        ON UPDATE CASCADE ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."cad_steps"
    VALIDATE CONSTRAINT "cad_steps_trace_id_fkey";

ALTER TABLE "public"."cad_steps"
    ADD CONSTRAINT "cad_steps_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."cad_steps"
    VALIDATE CONSTRAINT "cad_steps_user_id_fkey";

-- ---------------------------------------------------------------------------
-- cad_incumbents
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS "public"."cad_incumbents" (
    "id"                   uuid        NOT NULL DEFAULT gen_random_uuid(),
    "retrieval_key"        text        NOT NULL,
    "step_id"              uuid,
    "user_id"              uuid        NOT NULL,
    "status"               public.incumbent_status NOT NULL DEFAULT 'active',
    "write_score"          double precision,
    "promoted_at"          timestamptz NOT NULL DEFAULT now(),
    "replaced_at"          timestamptz,
    "replacement_step_id"  uuid,
    "metadata"             jsonb       NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT "cad_incumbents_pkey" PRIMARY KEY ("id")
);

ALTER TABLE "public"."cad_incumbents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_step_id_fkey"
        FOREIGN KEY ("step_id") REFERENCES public.cad_steps("id")
        ON DELETE SET NULL NOT VALID;

ALTER TABLE "public"."cad_incumbents"
    VALIDATE CONSTRAINT "cad_incumbents_step_id_fkey";

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_replacement_step_id_fkey"
        FOREIGN KEY ("replacement_step_id") REFERENCES public.cad_steps("id")
        ON DELETE SET NULL NOT VALID;

ALTER TABLE "public"."cad_incumbents"
    VALIDATE CONSTRAINT "cad_incumbents_replacement_step_id_fkey";

ALTER TABLE "public"."cad_incumbents"
    ADD CONSTRAINT "cad_incumbents_user_id_fkey"
        FOREIGN KEY ("user_id") REFERENCES auth.users("id")
        ON UPDATE CASCADE ON DELETE CASCADE NOT VALID;

ALTER TABLE "public"."cad_incumbents"
    VALIDATE CONSTRAINT "cad_incumbents_user_id_fkey";

-- One active incumbent per (user, retrieval_key)
CREATE UNIQUE INDEX IF NOT EXISTS "cad_incumbents_active_per_user_key"
    ON public.cad_incumbents ("user_id", "retrieval_key")
    WHERE status = 'active';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS "idx_cad_traces_user_id"           ON public.cad_traces ("user_id");
CREATE INDEX IF NOT EXISTS "idx_cad_traces_conversation_id"   ON public.cad_traces ("conversation_id");
CREATE INDEX IF NOT EXISTS "idx_cad_traces_status"            ON public.cad_traces ("status");

CREATE INDEX IF NOT EXISTS "idx_cad_steps_trace_id"           ON public.cad_steps ("trace_id");
CREATE INDEX IF NOT EXISTS "idx_cad_steps_user_id"            ON public.cad_steps ("user_id");
CREATE INDEX IF NOT EXISTS "idx_cad_steps_subgoal_normalized" ON public.cad_steps ("subgoal_normalized");
CREATE INDEX IF NOT EXISTS "idx_cad_steps_eligibility"        ON public.cad_steps ("eligibility_status");
CREATE INDEX IF NOT EXISTS "idx_cad_steps_compile_result"     ON public.cad_steps ("compile_result");
CREATE INDEX IF NOT EXISTS "idx_cad_steps_tags"               ON public.cad_steps USING GIN ("tags");

CREATE INDEX IF NOT EXISTS "idx_cad_incumbents_user_id"       ON public.cad_incumbents ("user_id");
CREATE INDEX IF NOT EXISTS "idx_cad_incumbents_step_id"       ON public.cad_incumbents ("step_id");
CREATE INDEX IF NOT EXISTS "idx_cad_incumbents_retrieval_key" ON public.cad_incumbents ("retrieval_key");

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."cad_traces"     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."cad_steps"      TO authenticated;
GRANT SELECT                          ON TABLE "public"."cad_incumbents" TO authenticated;

GRANT ALL ON TABLE "public"."cad_traces"     TO service_role;
GRANT ALL ON TABLE "public"."cad_steps"      TO service_role;
GRANT ALL ON TABLE "public"."cad_incumbents" TO service_role;

-- ---------------------------------------------------------------------------
-- RLS Policies
-- ---------------------------------------------------------------------------

-- cad_traces
CREATE POLICY "Users manage their own traces"
    ON public.cad_traces
    AS PERMISSIVE FOR ALL
    TO authenticated
    USING  ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

-- cad_steps
CREATE POLICY "Users manage their own steps"
    ON public.cad_steps
    AS PERMISSIVE FOR ALL
    TO authenticated
    USING  ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

-- cad_incumbents — read only for authenticated; writes are service_role only
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
