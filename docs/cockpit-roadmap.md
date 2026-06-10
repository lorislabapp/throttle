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

## Validated this session (autonomous pass)
- **Dedup detector** works — found 5 real duplicated blocks across 4 projects each (asc-mcp guidance, "file path + line number", audit toolkit). Detect-only v1 shipped.
- **MCP probe** bug fixed — it was the reader (byte-at-a-time `bytes.lines` starved under 11 concurrent probes), NOT the timeout: audit-mcp/lorislab-web respond <0.5s from a shell. Now chunked POSIX read + concurrency cap 4 + 25s ceiling + "no resp" label.
- **Model `Fable 5`** is real in the DB (`claude-fable-5`); now shown by real name, not "Other". `<synthetic>` events carry 0 weighted → harmless.
- **Resume** now `cd`s to the project before `claude --resume`.
- **Data integrity** sanity-checked vs `com.lorislab.throttle/usage.db` — cockpit numbers are accurate (no faked values).
- **"LATEST SESSION"** relabel + project name (honest: it's the globally-latest session, not the cockpit terminal's).

## Next (prioritized)

1. **Dedup apply (phase 2)** — the detector is shipped; the destructive half (create the shared skill + remove the block from each CLAUDE.md, with diff preview + atomic backup + rollback) is the remaining work. Wire to a "Hoist" action in the dedup sheet. Stays 100% local.
2. **Config-weight "Optimize" button** → route CLAUDE.md/skills trimming through Throttle's existing AI assistant/optimizer (diff+rollback).
3. **Session summary** — show the 1st user prompt of the session `.jsonl` as the "what" (beyond the repo name).
4. **"THIS SESSION" → cockpit terminal** — deeper version: watch for the newest `.jsonl` created after the terminal launches and bind the strip to THAT session (currently shows the globally-latest, relabeled honestly).
5. **Floating HUD (NSPanel)** — lift the compact HUD into a borderless always-on-top panel over ANY terminal (the "SwiftTerm prison" hedge; HUD already built decoupled).
6. **Prompt-gauge D** — opt-in Starship-style shell PS1 segment.
7. **MCP polish** — opt-in note that probing launches local servers; decode project/repo names containing dashes (lossy today).

## Guardrails (don't drift)
- Wedge = cockpit-around-the-agent, NOT a terminal. Non-goals: tabs/splits/themes/SSH/profiles, GitHub/third-party/cloud/accounts.
- Golden rule: never render a faked number — degrade (≈/est/hide).
- App Store off the table (terminal spawns a process) → notarized direct + Sparkle.
