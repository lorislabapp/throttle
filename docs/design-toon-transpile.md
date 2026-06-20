# Design — TOON transpile (PostToolUse token-saver)

**Goal:** cut context tokens by transpiling bloated JSON tool outputs (uniform
arrays) into a compact format before they persist in the model's context.
Fits the wedge (cut tokens), local-only (USP), Throttle manages the hook.

## Feasibility (verified against Claude Code docs)
- PostToolUse hooks can RETURN `hookSpecificOutput.updatedToolOutput` which
  **replaces** the tool-result bytes stored in context (not just append).
  Source: code.claude.com/docs/en/hooks.md → PostToolUse.
- `additionalContext` only APPENDS (would *increase* tokens) — must NOT use that.
- PostToolUse is the ONLY event that can rewrite a tool result in-flight.
- → Buildable. Savings persist for every subsequent turn that re-reads context.

## The real risks (why this is opt-in + guarded, not blind)
1. **Model comprehension.** TOON is niche; if Claude misreads it, accuracy drops.
   Mitigation: start with transforms Claude provably understands; gate behind eval.
2. **Corruption / lossy.** A bad transpile feeds the model wrong data.
   Mitigation: lossless only; round-trip check (TOON→JSON == original) before replacing.
3. **Wrong target.** Some tools' outputs must stay exact JSON (model parses them).
   Mitigation: per-tool allowlist — never transpile globally.
4. **Hook cost.** Slow transpiler eats the savings. Mitigation: fast, no per-call subprocess.

## Staged plan (safe-first)
### Phase 1 — MEASURE ONLY (zero risk, ship first)
- Throttle installs a PostToolUse hook (managed like `session-start-router.sh`).
- Hook reads the tool result; if it's JSON with a uniform array above a size
  threshold, compute `jsonTokens` vs `toonTokens` and LOG the would-be saving to
  Throttle's savings store (`tokopt_savings`). **Never replaces output.**
- Optimizer UI shows: "TOON could save ≈X tokens/week across N tool calls."
- User sees the value with zero behavioural change. This alone is shippable.

### Phase 2 — OPT-IN REPLACE (off by default)
- Toggle in Optimizer + a per-tool/per-MCP **allowlist** (user picks which tools).
- For allowlisted tools only: transpile → round-trip verify lossless → measure;
  replace via `updatedToolOutput` ONLY if (valid TOON) AND (smaller) AND (round-trips).
  Otherwise passthrough unchanged. **Never make it worse, never corrupt.**
- One-switch disable; nothing persists in claude config beyond the managed hook.

### Phase 3 — REALIZED SAVINGS
- Track actual replaced bytes → real tokens saved into the existing savings system,
  attributed per tool. Closes the detect→cost-attribute→optimize loop.

## Open question to resolve before Phase 2
Does Claude reliably interpret TOON vs a safer compact form (minified JSON, or
CSV for uniform arrays)? Phase 1's measurement + a small accuracy eval answers
this. If TOON comprehension is shaky, ship the same pipeline with minified-JSON /
CSV (still a real saving, zero comprehension risk).

## Throttle scope check
✅ cuts tokens · ✅ local-only · ✅ Throttle owns the hook + UI + attribution.
Off by default; opt-in; lossless-or-passthrough. No data-path proxy, no cloud.

## Phase 2 upgrade — CCR (Compress-Cache-Retrieve), NotebookLM 2026-06-20
Stronger variant of "transpile in place". Instead of (or on top of) reformatting
the output, REPLACE a verbose tool result with a tiny pointer and stash the raw
text in a local SQLite cache; claude pulls the full text back only if it needs it.
- **Mechanism:** `PostToolUse` hook → if the output is large + low-signal (e.g.
  `npm install`, `cargo build` chatter), write the raw bytes to a local cache
  keyed by hash, and emit `hookSpecificOutput.updatedToolOutput` = a ~50-token
  pointer: a one-line summary + "call `throttle_expand(hash=…)` for the full
  output". Needs a tiny bundled MCP tool `throttle_expand` so claude can retrieve.
- **Claimed gain:** up to ~89% on CLI-noise tokens (tool results ≈60% of agentic
  context). MUST be confirmed against our own `toon-potential.jsonl` before ship —
  do not render the headline number until measured (golden rule).
- **Golden-rule guardrail (hard no-op):** if the command FAILED (non-zero exit),
  wrote to stderr, contains a stack trace / error, or is structured JSON the model
  likely needs verbatim → emit nothing, pass the FULL original through. Compress
  only provably-low-signal success output. PostToolUse runs AFTER execution, so it
  never bypasses Claude Code's permission prompts (unlike PreToolUse rewriting).
- **Scope check:** native hook + local cache + local MCP retrieval tool = no proxy,
  no cloud. Opt-in, per-tool allowlist. This supersedes the plain-transpile plan as
  the Phase 2 target; keep minified-JSON/CSV as the fallback encoding inside it.
