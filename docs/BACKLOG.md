# Throttle — backlog (deferred, as of 2026-06-20, post-3.2.2)

Nothing here is broken or urgent. These are deferred-on-purpose or on-demand.
Current shipped version: **3.2.2** (build 102).

## Shipped in 3.2.2 (2026-06-20)
- [x] **Rate-limit handling** — DroppableTerminalView detects claude's usage-limit
      banner, parses the reset time; CockpitTab `.rateLimited` state (red dot +
      countdown), model aggregates a red banner + a "which project" notification.
- [x] **Duplicate-session detect + consolidate** — `duplicateCwds` + a banner with
      1-click Consolidate (hibernate extras, keep most-recent, resume-id kept).
- [x] **Throttle Health check** — HealthCheckService + HealthCheckView (stethoscope
      button): tracking-live, dedup index, DB integrity/size, orphaned procs (1-click
      kill), memory, disk, exact-mode, cache-busting hooks.
- [x] **Circuit-breaker (safe half)** — manual SIGSTOP/SIGCONT Pause/Resume per
      session (`signalSubtree`, rail hover button, `.paused` state). Auto-pause
      still deferred per design verdict.
- [x] **Xcode-errors→claude** — XcodeBuildErrorsService distills the newest .xcresult
      (via xcresulttool) → terminal right-click "Paste latest Xcode build errors".
- [x] **Project detail** (Stats: working-since/total-time/last-active), **session
      sort** (activity/cost/RAM/name/waiting), **rich state dot** (fixes gray
      flicker), **reset countdown** (HH:MM), **/wk projection label** clarified.

## Build on explicit go
- [ ] **Auto-pause (true ACT)** — the deferred risky half: ≥97% + burn ETA <5min,
      opt-in, countdown-cancelable, reuse the new SIGSTOP/CONT pause. Gated on user
      demand (design verdict). Per-model "switch to cheaper" nudge is the softer
      variant. Design: `docs/design-circuit-breaker.md`.
- [ ] **Rate-limit pacing/Retry-After** — extend 3.2.2's detection: predictive
      cross-session pacing before the wall + honor Retry-After on claude.ai 429s
      (detection + surfacing already shipped).
- [ ] **TOON Phase 2 → CCR (Compress-Cache-Retrieve)** — upgraded target (NotebookLM
      2026-06-20): a `PostToolUse` hook replaces verbose low-signal tool output with
      a ~50-token pointer + stashes the raw text in a local SQLite cache; a bundled
      `throttle_expand(hash)` MCP tool lets claude pull it back on demand. HARD no-op
      on failures/stderr/stack-traces/JSON the model needs. WAIT for `toon-potential.
      jsonl` data to confirm the gain before ship. Design: `docs/design-toon-transpile.md`.
- [ ] **Read-Firewall / local-RAG auto-config** — detect brute-force file reading
      (≥N sequential reads or >150 KB/turn), attribute the waste per project, and
      offer a 1-click (preview + revert) inject of `mcp-local-rag` (local LanceDB,
      no cloud) into the project `.mcp.json`. Watch the lossy-recall golden-rule
      risk. Design: `docs/design-read-firewall.md`.
- [ ] **TOON readout UI** (Phase 1.5) — surface accumulated potential savings from
      `toon-potential.jsonl` in the Optimizer.

## Stats polish (small)
- [ ] Reset shows clock time → add an HH:MM countdown in the menu-bar dropdown too
      (cockpit binding already has it as of 3.2.2).

## Parked — premise unverified
- [ ] **MEMORY.md 200-line cap audit / segmentation** — the claim "Claude Code
      silently truncates CLAUDE.md/MEMORY.md autoload at ~200 lines" was NEVER
      verified (the claude-code-guide check failed). Do NOT build a "your config is
      truncated" feature until confirmed real (golden rule: don't render a claim we
      can't stand behind). Autopilot already archives stale/orphaned memory.

## Designed → verdict NO / defer (don't build unless asked)
- **Keep-alive cache pings** — verdict: don't ship (spend + ToS + cap pressure).
  `docs/design-keepalive-pings.md`
- **Semantic dedup cache** — verdict: no (no-proxy non-goal + wrong-cache-hit risk).
  `docs/design-semantic-dedup-cache.md`
- **AX-tree extraction** — buildable via a `ui_snapshot` MCP tool, but narrow
  audience → defer. `docs/design-ax-tree-extraction.md`
- **B2B Team/Enterprise tier** — deferred per doctrine (behind first consumer sales).

## Housekeeping
- [ ] Quit the lingering 3.1.7 Debug GUI instance (cosmetic; it auto-relaunches —
      quit from its menu-bar icon).
- [ ] `lorislab-website` repo is committed locally but not pushed to its GitHub
      remote (prod is already deployed via deploy.mjs).
