-- =============================================================================
-- Upgrade: harden match_cad_incumbents for deployments that already ran
-- 20260424230000 with the old (3-arg) signature.
-- =============================================================================

DROP FUNCTION IF EXISTS "public"."match_cad_incumbents"(vector(1536), integer, text[]);

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
