import { Database } from './database.ts';
export type Model = string;
export type CreativeModel = 'quality' | 'fast' | 'ultra';

export type Prompt = {
  text?: string;
  images?: string[];
  mesh?: string;
  model?: Model;
};

export type Message = Omit<
  Database['public']['Tables']['messages']['Row'],
  'content' | 'role'
> & {
  role: 'user' | 'assistant';
  content: Content;
};

export type CoreMessage = Pick<Message, 'id' | 'role' | 'content'>;

export type MeshFileType = Database['public']['Enums']['mesh_file_type'];

export type Mesh = {
  id: string;
  fileType: MeshFileType;
};

export type MeshData = Omit<
  Database['public']['Tables']['meshes']['Row'],
  'prompt'
> & {
  prompt: Prompt;
};

export type ToolCall = {
  name: string;
  status: 'pending' | 'error';
  id?: string;
  result?: { id: string; fileType?: MeshFileType };
};

export type Content = {
  text?: string;
  model?: Model;
  // When the user sends an error, its related to the fix with AI function
  // When the assistant sends an error, its related to any error that occurred during generation
  error?: string;
  artifact?: ParametricArtifact;
  index?: number;
  images?: string[];
  mesh?: Mesh;
  // Parametric mode: bounding box dimensions from STL parsing
  meshBoundingBox?: { x: number; y: number; z: number };
  // Parametric mode: original filename for import() in OpenSCAD
  meshFilename?: string;
  suggestions?: string[];
  // For streaming support - shows in-progress tool calls
  toolCalls?: ToolCall[];
  // Mesh topology preference (quads vs polys) for quality model
  meshTopology?: 'quads' | 'polys';
  // Polygon count preference for quality model
  polygonCount?: number;
  // File format preference for quad topology models
  preferredFormat?: 'glb' | 'fbx';
};

export type ParametricArtifact = {
  title: string;
  version: string;
  code: string;
  parameters: Parameter[];
  suggestions?: string[];
};

export type ParameterOption = { value: string | number; label: string };

export type ParameterRange = { min?: number; max?: number; step?: number };

export type ParameterType =
  | 'string'
  | 'number'
  | 'boolean'
  | 'string[]'
  | 'number[]'
  | 'boolean[]';

export type Parameter = {
  name: string;
  displayName: string;
  value: string | boolean | number | string[] | number[] | boolean[];
  defaultValue: string | boolean | number | string[] | number[] | boolean[];
  // Type should always exist, but old messages don't have it.
  type?: ParameterType;
  description?: string;
  group?: string;
  range?: ParameterRange;
  options?: ParameterOption[];
  maxLength?: number;
};

export type Conversation = Omit<
  Database['public']['Tables']['conversations']['Row'],
  'settings'
> & {
  settings: ConversationSettings;
};

export type GenerationStatus = Database['public']['Enums']['generation-status'];

export type ConversationSettings = {
  model?: Model;
} | null;

export type Profile = Database['public']['Tables']['profiles']['Row'];

// =============================================================================
// CAD trace memory — Part 1: Execution units & library roles
// Glossary ref: docs/glossary-cad-vector-memory.md §Part 1 of 4
// =============================================================================

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/** Lifecycle of a Trace. */
export type TraceStatus = 'running' | 'completed' | 'abandoned';

/**
 * Result of deterministic compile checks on a Step's FeatureScript.
 * 'uncertain' means heuristics could not decide — LLM judge or human review needed.
 */
export type StepCompileResult = 'success' | 'failure' | 'uncertain';

/**
 * Gate result for a Candidate Step.
 * 'pending'    — gates have not yet run
 * 'eligible'   — all required gates passed; step may compete for Incumbent
 * 'ineligible' — at least one required gate failed; step cannot win Incumbent
 */
export type StepEligibilityStatus = 'pending' | 'eligible' | 'ineligible';

/**
 * Result of the LLM judge pass on a Step's FeatureScript.
 */
export type StepJudgeOutcome = 'pass' | 'fail' | 'uncertain';

/**
 * Lifecycle of an Incumbent record.
 * Only one 'active' row per (user_id, retrieval_key) is enforced by the DB.
 */
export type IncumbentStatus = 'active' | 'retired';

// ---------------------------------------------------------------------------
// Weights & Scoring (Part 2)
// ---------------------------------------------------------------------------

export interface BalancedWriteWeights {
  token_count: number;
  turn_count: number;
  latency_ms: number;
  // Extensible for future metrics
  [key: string]: number;
}

export interface SessionWeights {
  token_count: number;
  turn_count: number;
  latency_ms: number;
  // Extensible for future metrics
  [key: string]: number;
}

// ---------------------------------------------------------------------------
// CadTrace — one end-to-end or partial recorded run toward a user goal
// ---------------------------------------------------------------------------

export type CadTrace = {
  id: string;
  user_id: string;
  /** nullable: headless / API sessions may have no conversation row */
  conversation_id: string | null;
  status: TraceStatus;
  /** Free-text goal expressed at trace start */
  goal_text: string | null;
  /** OpenRouter / model identifier (e.g. "anthropic/claude-sonnet-4-5") */
  model_id: string | null;
  /** Raw metrics — source-of-truth for scoring */
  raw_token_count: number;
  turn_count: number;
  started_at: string;
  completed_at: string | null;
  /** Versioned JSON for future raw metrics: latency_ms, cost_usd, etc. */
  metadata: Record<string, unknown>;
};

export type CadTraceInsert = Omit<CadTrace, 'id' | 'started_at'> &
  Partial<Pick<CadTrace, 'id' | 'started_at'>>;

export type CadTraceUpdate = Partial<Omit<CadTrace, 'id'>>;

// ---------------------------------------------------------------------------
// CadStep — bounded milestone (subgoal) inside a trace; unit of embed/score/retrieve
// ---------------------------------------------------------------------------

export type CadStep = {
  id: string;
  trace_id: string;
  user_id: string;
  /** Human-readable subgoal text as emitted by the agent / user request */
  subgoal_text: string;
  /** Normalised form used as the retrieval key seed */
  subgoal_normalized: string | null;
  /** SHA-256 hex digest of featurescript_code; used for dedup and audit */
  featurescript_hash: string | null;
  /** Inline FeatureScript (OpenSCAD) code produced for this step */
  featurescript_code: string | null;
  token_count: number;
  turn_count: number;
  latency_ms: number | null;
  /** Populated by deterministic-check gate (Part 3) */
  compile_result: StepCompileResult;
  judge_outcome: StepJudgeOutcome | null;
  confidence_score: number | null;
  /**
   * Eligibility gate result (Part 3).
   * Starts 'pending'; gates flip to 'eligible' or 'ineligible'.
   */
  eligibility_status: StepEligibilityStatus;
  /** Tag vocabulary: e.g. ['primitive:box', 'op:fillet', 'pattern:linear'] */
  tags: string[];
  /** 0-indexed position within the trace */
  step_index: number;
  created_at: string;
};

export type CadStepInsert = Omit<CadStep, 'id' | 'created_at'> &
  Partial<Pick<CadStep, 'id' | 'created_at'>>;

export type CadStepUpdate = Partial<Omit<CadStep, 'id'>>;

// ---------------------------------------------------------------------------
// CadIncumbent — current winning stored solution for a retrieval key (per user, v1)
// ---------------------------------------------------------------------------

export type CadIncumbent = {
  id: string;
  /**
   * Deterministic key: SHA-256 of (subgoal_normalized + '|' + sorted_tags).
   * Application code computes this before upserting.
   */
  retrieval_key: string;
  /** The step that currently (or previously) holds this slot */
  step_id: string | null;
  user_id: string;
  status: IncumbentStatus;
  /**
   * Composite score computed with balanced write weights at promotion time.
   * Higher = better (convention fixed project-wide).
   */
  write_score: number | null;
  promoted_at: string;
  /** Populated when superseded */
  replaced_at: string | null;
  /** Points to the step that replaced this record (audit trail) */
  replacement_step_id: string | null;
  embedding_model_id: string | null;
  /** Dense vector (1536-dim default) */
  embedding: number[] | null;
  /** Versioned JSON for future incumbent metadata: write_weights, judge_outcome, etc. */
  metadata: Record<string, unknown>;
};

export type CadIncumbentInsert = Omit<CadIncumbent, 'id' | 'promoted_at'> &
  Partial<Pick<CadIncumbent, 'id' | 'promoted_at'>>;

export type CadIncumbentUpdate = Partial<Omit<CadIncumbent, 'id'>>;
