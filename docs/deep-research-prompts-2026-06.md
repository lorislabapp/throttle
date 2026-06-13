# Throttle v3.0 — deep-research prompts (2026-06-13)

Ready-to-paste prompts (Perplexity / Claude deep research) to reach SOTA on each
remaining topic. Shared preamble below; paste it before each prompt's TASK so the
model doesn't re-suggest what we already ship.

---

## SHARED PREAMBLE (paste before every TASK)

> Role & Context: I'm building "Throttle v3.0", a native macOS **cost & health cockpit FOR a Claude Code AIOS** (NOT a terminal/IDE/agent-orchestrator — we audit and optimize, we never become the execution engine). It cuts Anthropic token waste WITHOUT degrading the model's coding or reasoning quality. 100% local, no cloud.
> What we ALREADY ship (do NOT re-suggest): Caveman output-terseness injection; RTK proxy compressing CLI stdout 60–90%; stale-memory archiver (30d+); model-routing nudges (>70% Opus/Fable → Sonnet); dead-skill analytics + archive; CLAUDE.md dedup → hoist-to-skill; prompt-cache hygiene audit (flags hooks that bust the cache); read-firewall audit that recommends mcp-local-rag; MCP `list_tools` health; official-rate cost (Fable 5 = $10/$50). Skills/MCP/memory/CLAUDE.md weight audit.
> Constraints: macOS-native (Swift/Rust, Apple Silicon, MLX/CoreML/Vision/PDFKit OK); reversible/backed-up edits only; the golden rule is NEVER show a wrong number and NEVER degrade reasoning.
> Search 2025–2026 dev blogs, GitHub, arXiv, HN, r/LocalLLaMA, r/MachineLearning. For each recommendation give: concrete approach, token-saving estimate, **quality risk**, implementation effort, and any open-source lib we can embed.

---

## 1. Multimodal / Vision token economy
TASK: Quantify the real token cost of images/PDFs/screenshots in Claude (per-image tokens by resolution, PDF page costs, the 2026 vision tokenizer). Then find SOTA for **local pre-processing before send**: Apple Vision OCR, the macOS Accessibility tree → structured text, PDFKit text extraction, image diffing/deltas, optimal crop+downscale. CRITICAL: how to decide when structure is enough vs when the raw image is genuinely needed (graphs, subtle UI) so we never blind the model. Give a decision tree + measured savings.

## 2. Input compression (LongLLMLingua family), quality-safe
TASK: Best 2025–2026 **input-text compressors** (LLMLingua-2, Provence, others) that preserve task-critical tokens. Which run fast 100% locally on Apple Silicon (MLX/CoreML/ONNX)? What are measured quality deltas on code/doc QA? Where is it SAFE vs unsafe to compress (logs/README = safe? code = dangerous?). How to give the user a preview/diff + fallback. Rank by savings × (low) quality-risk.

## 3. Semantic dedup & response/tool-result caching (anti-poisoning)
TASK: SOTA for **proxy-level dedup** of near-identical prompts and deterministic tool results (read_file/grep/tests on the same revision). Best lightweight local embedding models + SQLite-vector stores. The hard part: **cache-poisoning prevention** — how production systems classify idempotent vs stateful calls, invalidate on file/commit change, and set TTLs. Delta-encoding for agent refinement loops. Concrete safe-set definition.

## 4. Advanced prompt-cache exploitation
TASK: Beyond static-first ordering — undocumented/SOTA tricks to **maximize Anthropic prompt-cache hit-rate**: optimal cache-breakpoint placement, multi-agent shared-prefix design, keeping cache warm across the 5-min TTL, the Opus-4.7+ new-tokenizer impact, and how to **measure hit-rate locally** from ~/.claude logs (do the logs expose cache_read/cache_creation per turn?). Give the lint rules + the metric we can compute offline.

## 5. Local code-RAG / read-firewall (recommend, not build)
TASK: Compare 2025–2026 **lightweight local-RAG MCP servers** for serving code/markdown snippets instead of whole files: mcp-local-rag, codebase-ash, Zilliz claude-context, others. Evaluate AST-aware chunking quality, hybrid (BM25+vector) retrieval, **false-negative risk** (missing a needed snippet), incremental indexing, and zero-cloud macOS fit (sqlite-vec/VecturaKit). Which is the best to RECOMMEND/auto-configure from Throttle (we don't build the RAG). Include the exact mcp.json.

## 6. Context/memory virtualization (lossless), productized
TASK: Productizing **structurally-lossless context trimming** (the CMV paper, claude-code-cmv) + memory re-architecture (Cognis, Memory-Palace, Reverie): segment MEMORY.md into critical/decisions/logs, dedup-on-ingest, temporal boosting, compact-survival snapshots. What's proven lossless (preserves all user+assistant reasoning) vs risky? Measured reductions. The exact trim rules + invariants (never clobber manual edits).

## 7. Competitive / platform SOTA (stay ahead)
TASK: What do the best Claude-Code cost/optimization tools and Anthropic's own surfaces do as of mid-2026 (Anthropic usage dashboard, Claude Code Desktop, ccusage, Claudia/opcode, new entrants)? Where is the **white space** a cost-&-health cockpit still uniquely owns, and what's the single biggest platform-dependency risk (Anthropic shipping native cost tooling)? Give defensible moats.
