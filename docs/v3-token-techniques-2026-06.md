# Throttle v3.0 — advanced token-saving techniques, triaged (2026-06-13)

Source NotebookLM. Two Perplexity deep-research docs (general token-saving + Code
RAG / markdown memory) + the CMV arXiv paper, triaged against the wedge
(detect → cost-attribute → optimize; never become the engine/RAG/IDE; 100% local;
never degrade reasoning quality).

## The line (definitive)
- **Being the Code RAG** (build the AST parser, vector index, search orchestration, polyrepo graph) → **REFUSE.** That's an execution engine = Cursor/Warp collision.
- **Auditing / filtering / recommending** → **ON-WEDGE.** Throttle is the **Read Firewall**: it detects a brute `read_file` on an 800-line file, intercepts, and routes to an EXISTING MCP (mcp-local-rag), returning snippets. The shield, not the engine.

## Triage of the 6 techniques

| # | Technique | Verdict | Token impact | Quality risk |
|---|---|---|---|---|
| 1 | **Prompt Cache Optimizer** — lint cache-busters (dynamic system prompt, static/dynamic mixing, tool-order churn), measure hit-rate, recommend stable prefix families | 🟢 **BUILD** | 41–80% input cost | **ZERO** |
| 2 | **Structurally-lossless memory/context trimming** — strip base64, raw tool-output dumps, metadata, thinking blocks; preserve every user message + assistant response verbatim (CMV paper: 20% mean, up to 86%) | 🟢 **BUILD** | strong | **ZERO** |
| 3 | Semantic prompt/tool-result dedup — local cache of responses/tool results (exact + semantic) | 🟢 build, but R&D | 15–60% calls avoided | medium (cache poisoning → restrict to idempotent tasks) |
| 4 | **Code RAG / vector DB** (sqlite-vec, VecturaKit, AST graph) | 🔴 **RECOMMEND, don't build** | 30–60% code ctx | medium (false negatives) |
| 5 | Vision → OCR / Accessibility-tree + crops instead of raw images | 🟡 later | 2–5× image tokens | **high** (loses non-textual info) |
| 6 | LongLLMLingua — compress input text (logs/docs) via a small local model | 🟡 later | 20–40% non-code text | medium (may drop needed tokens) |

## Prioritization

- **Phase 1 — implement NOW (truly on-wedge, zero quality risk):**
  1. **Prompt Cache Optimizer.** Max ROI, low effort (linting + metrics). Feasible static path: audit CLAUDE.md / settings / **hooks** (e.g. a SessionStart hook injecting a dynamic prelude busts the cache) for cache-busting patterns; recommend static-first ordering + stable prefixes. Anthropic surfaces nothing about your cache efficiency.
  2. **Lossless memory/context trimming.** Extends the stale-memory detector: detect structural bloat (base64, raw logs, metadata) in memory files and offer a lossless trim that keeps all prose/reasoning. Fast (text manipulation). Backed by CMV (github.com/CosmoNaught/claude-code-cmv).
- **Phase 2 — audit & orchestrate (NOT build):** the **Read Firewall** — an interception rule that audits big reads, flags the waste, and recommends / auto-configures `mcp-local-rag`. Throttle owns the *rule*, not the RAG.
- **Phase 3 — R&D, paused:** semantic proxy dedup (needs a local SQLite vector store), Vision OCR + LongLLMLingua (quality risk + extra local models). Revisit post-MVP.

## Note on existing features (from Kevin's own framing in the docs)
Kevin lists as ALREADY-DONE: Caveman, RTK integration, memory cleanup, model nudges, ContextShield (read-blocking), anti-compaction alerts, config-weight audit. Some (ContextShield read-blocking, anti-compaction as a hook) are aspirational vs shipped — reconcile with the real build before claiming them.

## Guardrail
Filter unchanged: "does it stop hitting the cap unwarned, or cut tokens — without degrading reasoning?" Audit/recommend/filter = in. Build the engine = out.
