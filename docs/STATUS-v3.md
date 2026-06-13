# Throttle v3.0 — STATUS (single source of truth, 2026-06-13)

Master index after the big build+research session. Build is GREEN, git is clean.
Throttle is now the **cost & health cockpit FOR a Claude Code AIOS** ("CFO of your
setup"). Read this first; it links the detailed docs.

## SHIPPED — the audit suite (detect)
All in the Cockpit window → CONFIG WEIGHT rail + strip. Services in `Throttle/Services/`:
- **Config weight** — CLAUDE.md ≈tok, skills count.
- **Dedup** (`ConfigDedupService`) — duplicated blocks across project CLAUDE.md files.
- **Stale memory** (`MemoryCleanupService`) — `~/.claude/projects/*/memory/*.md` unused 30+ days.
- **Cache busters** (`CacheHygieneService`) — SessionStart/UserPromptSubmit hooks that inject dynamic content into the cached prefix.
- **Dead skills** (`SkillUsageService`) — installed skills never fired (greps `{name:Skill}` in transcripts).
- **Brute reads** (`ReadFirewallService`) — large files read repeatedly → recommend mcp-local-rag.
- **Context bloat** (`ContextBloatService`) — base64 images (1433/120 sessions ≈4.3M tok) + oversized tool_results.
- **MCP health** (`MCPHealthService`) — real `list_tools` probe (chunked POSIX read, login shell, capped concurrency).
- **Model nudge** + **forecast** + **session cost** — `CockpitQueries` + `PlanAdvisor` (official rates incl. Fable 5 $10/$50).

## SHIPPED — optimize actions (all reversible, backed up, never delete)
- **Archive dead skill** → `~/.claude/skills-archive`.
- **Archive stale memory** (per-file + bulk) → `~/.claude/memory-archive`.
- **Hoist dedup** → create shared skill + remove from each CLAUDE.md (backup → `~/.claude/throttle-backups`).
- **Recommend mcp-local-rag** (copy mcp.json) · **Switch to Sonnet** (passthrough) · **Resume** (cd + `claude --resume`).

## BLOCKED / ABANDONED (with proof — do not re-attempt)
- **Deterministic tool-result cache** — ABANDONED. Claude Code hooks can't substitute a tool result (verified); a CachedRead MCP would (1) cross into the engine, (2) bloat CLAUDE.md, (3) re-introduce TOCTOU poisoning. Recommend a 3rd-party MCP instead. See `v3-build-plan-2026-06.md`.
- **Semantic response cache** — opt-in Aggressive only (5-15% hit on code, poisoning). Off by default.
- **Input compression (LLMLingua)** — non-code only; NO-GO on code (edit-similarity drops). Deep research confirmed.
- **Code RAG engine / local-LLM orchestration / GitHub-style integrations / terminal tabs** — REFUSE (Warp/IDE scope creep).

## OPTIONAL remaining (the only on-wedge build left) — Surgical Context Trimmer (CMV brick 3)
Spec (from `Throttle Context Virtualization Productization.md`): a user-invoked, 3-pass,
schema-preserving, **lossless** trim that recovers 20-40% of context:
1. Byte-level scan (`String.includes`) to flag trimmable lines (no full JSON parse on every line).
2. Build a dependency ledger of live `tool_use` IDs in surviving assistant messages.
3. Strip ONLY mechanical bloat, keeping every user/assistant message + tool_use verbatim:
   - base64 image blocks → replace with a text pointer block (schema-valid),
   - `file-history-snapshot` / `queue-operation` / `scheduled_task_fire` metadata,
   - pre-`compact_boundary` superseded events,
   - tool_results > ~500 chars → stub,
   - orphaned tool_results (no matching tool_use) → archive.
**Why deferred:** doing it on the SAVED session jsonl (so `--resume` loads the lighter
version) requires schema-perfect JSON edits — corruption = data loss. Must be built
carefully (backup + validate the result re-parses + every tool_result keeps its tool_use),
NOT rushed. The `throttle_expand_pointer` MCP (re-hydrate a stub on demand) is the companion piece.

## Doc index
- `STATUS-v3.md` (this) · `v3-build-plan-2026-06.md` (verdicts + cache-blocked proof)
- `positioning-aios-cockpit-2026-06.md` (the wedge: CFO of an AIOS, the line)
- `cockpit-scope-decision-2026-06.md` (GitHub no / local env yes)
- `token-optimization-ideas-2026-06.md` · `v3-token-techniques-2026-06.md` (technique triage)
- `deep-research-prompts-2026-06.md` (7 SOTA prompts) · `cockpit-roadmap.md` · build/direction logs
- Strategy/research brain = NotebookLM "Throttle - Documentation" notebook.

## The one guardrail (unchanged)
Every feature: "does it stop hitting the cap unwarned, or cut tokens — WITHOUT degrading
reasoning?" Audit/recommend/reversible-edit = in. Become the engine = out. The platform
ceiling (hooks can't fake tool results) happens to ENFORCE this wedge.
