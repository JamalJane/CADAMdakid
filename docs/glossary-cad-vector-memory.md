# Glossary: CAD trace memory, scoring, and vector retrieval

This glossary supports the **FeatureScript CAD assistant** design: logging successful runs, **similarity retrieval** of past solutions, **default balanced scoring** to pick **global incumbents**, **per-session weight sliders** for **individual re-ranking**, **deterministic checks + LLM judge**, **human review after uncertainty**, and **exploration** so behavior does not collapse to a single recipe.

**Vector store decision (normative):** Use **pgvector** on **Supabase Postgres** as the **primary** vector store (vectors live beside relational metadata, same RLS/backups/migrations story). **Pinecone** (or another hosted ANN service) is an **optional later migration** if scale or ops requirements outgrow Postgres—same embeddings and app logic; only the **storage/query layer** changes. An API key alone does not integrate anything; **application code** must embed, upsert, and query.

---

## Part 1 of 4 — Execution units & library roles

**Trace**  
One end-to-end or partial **recorded run** toward a user goal: prompts, model outputs, **FeatureScript** (or deltas), tool calls, and **raw metrics** (tokens, turns, timings, compile result). Stored for analytics and for promotion into the shared library.

**Step / subgoal**  
A **bounded milestone** inside a trace (e.g. “create axis-aligned box primitive,” “apply fillet set,” “linear pattern ×6”). Steps are what you **embed**, **score**, and **retrieve** at the right grain—not necessarily every LLM token. When the library promotes **step-level** rows, **candidate** and **eligible** status attach to **step records** linked to the parent trace; when promotion is **trace-level only**, those statuses attach to the **whole trace**.

**Incumbent**  
The **global** **current winning** stored solution for a given **retrieval key** (e.g. **org/tenant scope** plus **canonical subgoal** identifier and tag set—**policy** defines whether paraphrases collapse to one key or stay distinct): the FeatureScript or recipe snapshot that **competed under balanced write weights** and beat previous challengers. Only one primary incumbent per key unless you later allow **multiple incumbents** per key (distinct from **retrieval top‑k**, Part 2).

**Candidate trace**  
A completed (or partial) trace that **might** replace the **global** incumbent **if** it passes **quality gates** and earns a competitive **composite score** (see **promotion path**, Part 3). Candidates may be logged even when they do not win. The same lifecycle applies to **candidate step** rows when embeddings and metrics are stored **per step / subgoal** rather than only at trace granularity.

**Eligible trace**  
A candidate that **passed all required quality gates** (e.g. compile success, deterministic pass, LLM judge pass when required) and is allowed to **receive a composite score** and compete for incumbent or for user-facing ranking. **Eligible step** denotes the same state for **step-level** library rows when the product uses that grain.

---

## Part 2 of 4 — Scoring, weights, and read path

**Raw metrics**  
Structured, versioned measurements attached to a trace or step: e.g. **token** counts, **FeatureScript** size, **turn** count, latency, compile flag, judge outcome codes. **Scores are derived from raw metrics**, not stored as the only truth without the underlying numbers.

**Normalization**  
Maps each raw metric to a **common scale** (e.g. bounded 0–1, z-score within cohort, or log-scaled counts) so no single dimension (often tokens) dominates the composite score by magnitude alone. **Normalization rules are versioned** with the scorer so historical rows remain interpretable.

**Weight vector**  
The ordered set of coefficients applied to **normalized** metrics when forming a **composite score**. **Balanced write weights** and **session weights** are two instances of the same shape: same metrics, different coefficients for **library promotion** vs **per-session display order**.

**Composite score**  
A single **comparable number** (or ordered tuple) combining **normalized** raw metrics with a **weight vector**. **Higher or lower** convention must be fixed project-wide (e.g. “higher is better”). Used to pick winners among **eligible** traces **or step-level** rows.

**Balanced write weights**  
The **fixed default** weight vector used **only** when **promoting or replacing the global incumbent** in the vector-backed library. Keeps the shared index from chasing one power user’s slider. **Individual users do not rewrite the incumbent** with their session weights.

**Session weights**  
Weights from the **per-session slider** (token vs speed vs FS-efficiency emphasis). Applied on **read**: **re-rank** or **re-score** retrieved candidates for **this session only**, using the same stored **raw metrics**.

**Retrieval**  
Given a query (user text + context), **find nearest neighbors** in the vector index (pgvector), fetch **metadata + metrics + script snippets**, then **rank** with session weights. Retrieval is **exploit**; it is paired with **exploration** so new data still enters the system.

**Candidate pool (retrieval top‑k)**  
The **set of index hits** returned by ANN search before session re-ranking (not the same as a **candidate trace** in Part 1—here “candidate” means **neighbor**): typically **top‑k** by embedding distance (plus optional **metadata filters**, dedupe by script hash, or minimum similarity). **k** is a product constant; final **order shown to the model** may differ after **session weights** and business rules.

**Read path**  
The **query-time pipeline**: (1) build a **query embedding** from normalized subgoal / tags / constraints, (2) **ANN query** into pgvector for the **candidate pool**, (3) load **sidecar metadata** and **raw metrics**, (4) **re-score or re-rank** with **session weights**, (5) return ranked snippets and pointers for context injection. **Does not** change stored incumbents or global scores.

**Query embedding**  
The **dense vector** computed at read time from the **current** user request (and optional context), used only for **similarity search** against stored step/trace embeddings. Distinct from **scoring**: neighbors are found by **cosine** (or chosen) distance in embedding space; **who wins for the user** in that session is still decided by **session-weighted** composite scores on the **candidate pool**.

---

## Part 3 of 4 — Quality gates, uncertainty, and exploration

**Quality gate**  
A single **checkpoint** in the promotion pipeline: compile success, a stage of **deterministic checks**, **LLM judge** outcome, policy flags, or (after review) a human decision. Output is typically **pass**, **fail**, or routes into **uncertain**. Gates are **ordered** so cheap checks run before expensive ones.

**Deterministic checks**  
Fast, rule-based validation of FeatureScript or artifacts (length, parse sanity, banned patterns, required structure). Output is **pass**, **fail**, or **uncertain** when heuristics cannot decide. A **quality gate** may wrap several checks as one stage.

**LLM judge**  
A **second model pass** (structured output) that checks semantic intent vs. delivered FeatureScript when deterministic checks are insufficient. Adds token cost, so it should sit **after** cheap deterministic failures are ruled out.

**Judge policy**  
Versioned rules for **when** the **LLM judge** runs: e.g. only after compile + deterministic pass, **sampling** rate for cost control, or required runs when tags mark high-stakes edits. Record **policy id** on judged rows for audit.

**Confidence threshold**  
A numeric or categorical cutoff (from heuristics, the primary model, or the judge) that can mark a trace or step **uncertain** without necessarily running every gate, or that escalates to **human review** when scores sit in a border band.

**Uncertain**  
Either deterministic or judge (or **confidence threshold**) indicates **low confidence**. Records in this state **do not win the global incumbent** until resolved—often via **human review** or a rerun with clearer constraints. Retrieval may still use them only if policy allows **down-ranked** or **exclude-from-incumbent** behavior.

**Human review**  
A **manual** queue or UI where operators or trusted users **approve**, **edit**, or **reject** traces or steps stuck in **uncertain**, or spot-check wins before they influence **global** promotion. Outcomes should be written back as **raw metrics** / audit fields so scoring and eligibility stay explainable.

**Explore vs exploit**  
**Exploit:** use retrieval + incumbents. **Explore:** sometimes **skip or down-weight** retrieval, try **variants**, inject **diversity** into reference sets, or relax similarity cutoffs so new recipes get trials. Keeps the metric corpus and index from freezing on one recipe. **Exploration rate** and triggers are **policy-driven** (versioned); explicit A/B UI is optional.

**Reference snippet**  
A **slice** of another user’s **successful** FeatureScript (or canonical sub-recipe) attached as context when a **common element** matches—often **partial**, not the whole project. Governed by **similarity thresholds**, **tag** overlap, and **privacy/redaction** rules.

**Promotion path (write-time)**  
The **library write pipeline** after a run: log **candidate** → run **quality gates** → mark **eligible** → compute **composite score** under **balanced write weights** → **replace or retain** the **global** incumbent and **upsert** the **vector index**. Symmetric to the **read path** (Part 2) but mutates durable library state only when policy allows.

---

## Part 4 of 4 — Vector infrastructure and records

**Embedding**  
A **dense vector** produced by an **embedding model** from normalized text (subgoal, tags, constraints)—the **corpus** vectors written at **promotion path** or step-ingest time. Identical **meaning** should map to **nearby** vectors so “build a box” and close paraphrases hit the same recipes. Must share **embedding model id**, **dimension**, **similarity metric**, and **text normalization** rules with **query embedding** (Part 2) or ANN results are meaningless.

**Embedding model**  
The **frozen** model (provider + name + revision) used to produce all vectors in an index generation. Store **embedding_model_id** (and optionally tokenizer/locale rules) on each **index record** so you can **re-embed** or reject queries that use a mismatched client.

**Similarity metric**  
The distance or inner product used for ANN and ranking in embedding space (e.g. **cosine**, **L2**, **inner product**). The **pgvector** index **opclass** and application queries must use the **same** metric; switching requires **re-index** or **re-embed** under a new index definition.

**Vector index**  
The data structure (backed by **pgvector**) that stores **embedding + sidecar metadata** per row and supports **approximate nearest neighbor** search. Rows are scoped by **tenant isolation** keys consistent with the **retrieval key** (Part 1). The **application** embeds, **upserts**, and **queries**; Postgres stores vectors, runs similarity ops, and enforces **RLS** like any other table.

**pgvector**  
PostgreSQL **extension** adding a `vector` type and similarity operators. **ANN indexes** include **HNSW** (often better recall/latency at higher memory) and **IVFFlat** (list-based; needs training data and periodic rebuilds as the corpus drifts). In this project, **pgvector on Supabase** is the **default** place to store embeddings **with** incumbent rows, **raw metrics**, and org/user keys—**no separate Pinecone required** for v1. Tune **ef_search**, **lists**, and **probes** per ops guidance as QPS and corpus size grow.

**Pinecone**  
A **hosted** vector database product. **Optional**: use if Postgres vector **scale or QPS** is insufficient or ops wants a dedicated ANN service. Requires **API key + client code + index config**; does **not** replace the need for an **embedding** pipeline, **similarity metric** alignment, or your **scoring** logic (Parts 2–3).

**Upsert (vector row)**  
An **insert-or-update** of one **index record** after a successful **promotion path** (Part 3) or policy-approved ingest: set the **embedding**, refresh **sidecar metadata** (metrics snapshot, eligibility, hashes), and bump **replacement history** when an incumbent changes. Failed or **uncertain** rows either **omit** the upsert or write a **non-winning** sidecar state per policy.

**Index record / sidecar metadata**  
The non-vector fields stored **with** each point: stable ids (**trace** / **step** / org), **embedding_model_id**, **raw metrics** snapshot, FeatureScript hash, tags (`primitive:box`, …), **quality gate** outcomes or eligibility flags, replacement history, and **pointers** (e.g. storage URL or row id) to the **full trace** for audit—not necessarily the entire script inlined. Enables **balanced write scoring** and **per-session read ranking** without duplicating full traces in the hot vector row.

**Tenant isolation (vector table)**  
**Org/tenant** (and user where needed) columns plus **Supabase RLS** so embeddings and sidecars are readable only within the same trust boundary as the rest of the app. ANN queries must always **filter** by tenant (or use a per-tenant index) so **nearest neighbors** cannot leak across customers.

**Re-embed / backfill**  
Batch job that recomputes **embeddings** when the **embedding model**, **dimension**, **similarity metric**, or **text canonicalization** for indexed text changes. Rewrites vector columns and may rebuild ANN indexes; old **embedding_model_id** rows should be migrated or invalidated in one controlled cutover.

---

## Revision

Update this file when terms (e.g. judge outputs, tag vocabulary, or vector store choice) change; bump a short **changelog** line at the bottom if others depend on it.
