# Throttle v3.0 — consolidated build plan (2026-06-13)

NotebookLM synthesis across the deep-research docs (Caching Design, Context
Virtualization, Local-RAG comparison, Prompt Caching, Compression Landscape,
Multimodal, Cost Cockpit Strategy), triaged through the wedge: audit/optimize
cost+health, never the execution engine/RAG/IDE, 100% local, never degrade reasoning.

## Verdicts

| Build area | Verdict | Token lever | Quality risk | Effort |
|---|---|---|---|---|
| **CMV — lossless context/memory virtualization** | 🟢 BUILD (next) | 20% mean, up to 86% | **ZERO** (mathematically lossless) | low (JSONL scan, string-manip) |
| **Deterministic tool-result cache** (Read/Grep/Glob, Git-Merkle crypto invalidation) | 🔴 **BLOCKED as designed** / 🟡 narrow opt-in MCP-wrapper only | massive in theory | zero | blocked |
| Vision/multimodal preprocessing | 🟢 BUILD | 2-5× images | medium (spatial blindness) | high |
| Semantic response cache | 🟡 opt-in Aggressive only | 5-15% code | high (poisoning) | high |
| Input compression (LLMLingua) | 🟡 non-code only / NO-GO on code | 20-40% prose | very high on code | high |
| Code-RAG / read-firewall | 🔵 RECOMMEND `mcp-local-rag` (shinpr) — done | 30-60% | medium | very low |

## Red line (confirmed)
An **active proxy that caches deterministic tool-results = 100% ON-WEDGE** — a
"CDN for the agent" ("we already paid to read this file at this commit, here's the
local answer"). It does NOT orchestrate, decide, or replace the terminal. The line
is crossed only if Throttle starts executing scripts / generating code for the agent.

## CMV detail (the next build)
3-pass scan of `~/.claude/projects/*/conversation.jsonl`. Strip only mechanical fat:
base64 images, file-history/metadata, oversized `tool_result` dumps, orphaned tool
results, thinking blocks (non-portable). Preserve **every user message + assistant
response byte-for-byte**. Replace stripped payloads with crypto pointers the agent
re-expands on demand (an MCP `throttle_expand_pointer`). Output a trimmed
compact-survival snapshot — never edit the live transcript.
- **Brick 1 (shipped):** base64-image bloat detector — 1433 embedded images / 120
  sessions ≈ 4.3M tokens re-charged on resume. Detect-only, read-only.
- **Brick 2 (next):** oversized tool_result + metadata detection (needs JSONL message
  parsing to stay lossless — never touch user/assistant content).
- **Brick 3:** produce a lossless trimmed snapshot file (new file, reversible).
- **Brick 4:** the `throttle_expand_pointer` MCP so the agent recalls a stub on demand.

## ⚠️ Deterministic cache — BLOCKED (verified via claude-code-guide, 2026-06-13)
Claude Code hooks CANNOT transparently substitute a tool result. A PreToolUse hook
can only deny / modify-inputs / add-context — there is NO `tool_result` / `cachedOutput`
/ `skipExecution` field. So "intercept Read → return cache → skip execution" is
**not buildable transparently**. Realistic-but-degraded options:
1. **MCP wrapper** `CachedRead`/`CachedGrep` — transparent but needs the agent to call
   the cached variant (opt-in CLAUDE.md rule), and Throttle would be SERVING reads →
   edges toward "becoming the engine" (wedge decision required before building).
2. **PostToolUse `updatedToolOutput`** — fires AFTER execution (saves model tokens, not
   execution latency); Read's output schema is undocumented → fragile.
3. Platform change (Anthropic adds a tool_result injection field) — unsupported.
Conclusion: the "biggest safe lever" is gated by a deliberate Claude Code safety
boundary. Do NOT build the transparent proxy. Revisit only as an explicit opt-in
MCP-wrapper decision.

## Deterministic cache detail (DESIGN ONLY — blocked, see above)
Needs Throttle/RTK to be an active proxy. Safe-set: cache Read/Grep/Glob/pure-tests;
bypass Write/Edit/Bash/WebFetch (undecidable). Key = SHA256(Tool+Args+file-SHA256 or
Git-tree-hash + commit). Workspace siloing by absolute repo path; commit-SHA not
branch name; canonicalize paths (anti traversal). Conservative mode default (exact
match, clean tree, Read-only, 1h TTL, semantic OFF). Aggressive = semantic +
dirty-tree + 30d pinned-commit TTL, with a Nudge + `--no-cache` escape hatch.
Embeddings: jina-embeddings-v2-base-code (local, 768-dim) in sqlite-vec. Hard
invariants: fail-open on any mismatch, never forge, never cross namespace, defer to
the human escape hatch, filesystem truth supersedes cache.

## Positioning (Cost Cockpit doc)
Frame Throttle as a quality/reliability cockpit (Health Score, RAG/MCP diagnostics,
remediation) — higher willingness-to-pay than a "budget calculator".
