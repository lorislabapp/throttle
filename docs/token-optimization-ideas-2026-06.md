# Throttle — token-optimization ideas, evaluated (2026-06-11)

Source NotebookLM. Five ideas raised for the next token-saving wave, evaluated
against the existing research (v3.0, compaction tax, RTK, wedge/non-goals).
Verdict per idea + prioritization.

## Verdicts

1. **Auto-switch model by phase** (big=plan, mid=execute, fast=debug).
   - Not native (no `opusplan` in the sources); model is set statically via `--model`/settings.
   - On-wedge as a **nudge, not auto-pilot** — Throttle can't see the semantic phase from outside.
   - Token lever: **massive**. >70% Opus in a session's model split is a financial heresy; Sonnet handles ~90% of editing at ~1/5 the cost (output billed 5:1 vs input).
   - **DO NOW (low UI effort)**: extend the existing "Switch to Sonnet" to actively alert when the session model split exceeds ~70% Opus/Fable.

2. **Persistent "what worked / didn't" memory across sessions.**
   - **Already 100% native**: Claude Code's `~/.claude/projects/<repo>/memory/` + `MEMORY.md` (loaded every session; bloats with stale files unused 30+ days).
   - Reimplementing = scope creep → **refuse**. **Auditing/cleaning** it = on-wedge.
   - **DO NOW (very low effort)**: a memory-cleanup detector (files unused 30+ days, duplicate notes), same pattern as the dedup detector → surface in cockpit + propose purge.

3. **Local LLM for mechanical work** (big Claude plans → local runs CLIs → Claude reviews).
   - **Scope creep mortel — REFUSE.** Sources cite local LLMs (MLX/Ollama) only as *competitors* (ModelHub, Wave). A local-LLM execution layer turns Throttle into a multi-model IDE → collision with Warp ($73M).
   - **Reframe**: what you wanted (offload mechanical work + compress CLI output) is **already solved by RTK** — the Rust proxy you already use, compressing CLI output 60–90% (cargo test 155→3 lines). The on-wedge move is **deeper RTK integration** (Throttle installs/manages RTK hooks), not building a local LLM.

4. **Local image/PDF → markdown before sending** (Apple Vision OCR + PDFKit).
   - **Absent from the sources, no token figures.** The corpus quantifies text compression (Caveman 65–75%), CLAUDE.md (5–10k), AST chunking (40%), but nothing on image/PDF token cost.
   - **NEEDS DEEP-RESEARCH** to quantify the token cost of images/PDFs in Claude Code before building an OCR module.

5. **Fable 5 is expensive → prioritize token-saving?**
   - Fable 5 isn't in the corpus (which predates it), but **yes regardless** — output tokens are 5:1 punitive and auto-compaction burns 20–30k silently. Token-saving is Throttle's entire reason to exist; a pricier model only sharpens it.

## Prioritization (impact / effort)

- **A — DO NOW (on-wedge, validated):**
  1. Memory cleanup detector (stale 30+ days) — high impact / very low effort.
  2. Model-complexity nudge (>70% Opus/Fable → active alert) — massive financial impact / low UI effort.
- **B — DEEP-RESEARCH FIRST:** image/PDF → markdown (quantify token cost).
- **C — REFUSE:** reimplementing memory (redundant with native), local-LLM orchestration (scope creep / Warp collision). Get the same win via RTK integration instead.

## Guardrail reminder
Filter every feature: "does it stop hitting the cap unwarned, or cut tokens?" Stay local, never become a terminal/IDE/multi-model orchestrator.
