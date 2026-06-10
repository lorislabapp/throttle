# Throttle Cockpit — roadmap & open threads (updated 2026-06-10)

The running list so nothing is forgotten across sessions. Strategy/research lives
in the NotebookLM "Throttle - Documentation" notebook; code architecture in the
`throttle` project skill; this file = what's done + what's next.

## Done (this session)

**Cockpit (committed):**
- Strip A — BINDING hero, FORECAST (honest burn-rate, hidden when ETA > reset or msgs > 500), THIS SESSION (tokens · ≈€ API-value · all-time).
- Rail B (collapsible) — OTHER WINDOWS · MODEL SPLIT (session, >70% Opus hint) · CONFIG WEIGHT (CLAUDE.md ≈tok / Skills) · MCP · RECENT SESSIONS (project name + Resume passthrough).
- Compact HUD over full-bleed terminal; full/compact + rail toggles.
- Model selector (passthrough `/model`, ×cheaper from PlanAdvisor rates) + Switch-to-Sonnet banner action.
- MCP health (GOAT) — real `list_tools` probe via login shell (PATH+secrets match CC), ok/slow/down + tools + latency; remote = HEAD only; on-demand (probe on open + ↻).
- Realism: forecast guardrails, € labelled API-value, MCP read from `~/.claude.json`.
- Files: `CockpitWindowRoot/Data/TerminalView/Controller`, `CockpitQueries`, `MCPHealthService`. Specs: `UI-SPEC-cockpit.md`, `docs/cockpit-{direction,scope-decision,build-log}-2026-06*.md`.

**Knowledge base:**
- Global skills `~/.claude/skills/{swift6-concurrency, apple-design, apple-silicon-perf}`.
- Project skill `Throttle/.claude/skills/throttle` (architecture/data-model/wedge).
- Global `~/.claude/CLAUDE.md` trimmed (SwiftUI/Swift6/perf detail → skills; backup `.bak-2026-06-10`).
- NotebookLM notebook synced (25 sources).

## Next (prioritized, all validated on-wedge)

1. **Config-weight "Optimize" button** (currently display-only) → wire to Throttle's existing AI assistant/optimizer (diff preview + atomic backup + rollback) for CLAUDE.md/skills trimming.
2. **Dedup / hoist optimizer** (NotebookLM verdict: GO absolu) — detect duplicated content across project CLAUDE.md files and propose hoisting to a shared global skill. Attaches to the Optimize button. Stays 100% local (never GitHub API). Ties to the 95KB→28KB / "30–40% fewer limit hits" promise.
3. **Session summary** — beyond the repo name, show the 1st user prompt of the session `.jsonl` as the "what".
4. **"THIS SESSION" semantics** — tie to the `claude` session actually running in the cockpit terminal (watch for the newest `.jsonl` created after launch), not just the globally-most-recent session.
5. **Floating HUD (NSPanel)** — lift the compact HUD into a borderless always-on-top panel over ANY terminal — the hedge against the "SwiftTerm prison" risk (power users won't abandon Warp/Ghostty). HUD already built decoupled for this.
6. **Prompt-gauge D** — opt-in shell PS1 segment (Starship-style) putting headroom in the prompt itself. Phase: shell integration, not SwiftUI.
7. **MCP health polish** — opt-in note that probing launches local servers; decode project names containing dashes (e.g. `Lumen-Cam` currently → `Cam`); verify GOAT probe results against known-good servers.

## Guardrails (don't drift)
- Wedge = cockpit-around-the-agent, NOT a terminal. Non-goals: tabs/splits/themes/SSH/profiles, GitHub/third-party/cloud/accounts.
- Golden rule: never render a faked number — degrade (≈/est/hide).
- App Store off the table (terminal spawns a process) → notarized direct + Sparkle.
