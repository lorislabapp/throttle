# Throttle — backlog (deferred, as of 2026-06-16, post-3.2.0)

Nothing here is broken or urgent. These are deferred-on-purpose or on-demand.
Current shipped version: **3.2.0** (build 100).

## Build on explicit go
- [ ] **Rate-limit handling, full** (greenlit 2026-06-20) — Kevin's pain: running
      many parallel sessions, some get blocked when the cap is hit. Detect a
      rate-limited/blocked session (from its transcript/output), flag WHICH
      sessions are throttled in the rail, predictive cross-session pacing before
      the wall (extends ThresholdNotifier.forecastCapETA), honor Retry-After on
      claude.ai 429s, and keep exact-mode backoff (already in 3.2.1). Pairs with
      the Health check.
- [ ] **Duplicate-session detect + consolidate** (greenlit 2026-06-20) — group
      tabs by cwd, flag groups >1 ("2 sessions on 360 → consolidate?"), 1-click
      hibernate-the-extra (resume-id preserved, frees RAM/tokens). Detect + ASK,
      never silent-kill (doctrine). Fold into the Health check. NOTE: cost shows
      identical across dup tabs because cost is per-PROJECT (cwd), not per-session.
- [ ] **Throttle Health check** (greenlit 2026-06-20) — a "Throttle Health" panel
      that aggregates operational self-checks with ✅/⚠️/❌ + 1-click fixes,
      reusing the existing audit services. Checks: tracking-live (last usage_event
      age), **orphaned node/claude processes** (the C01 RAM-leak class — reuse
      SystemMemoryService.subtreePids), exact-mode connected/fresh/backoff, hooks
      installed + cache-busters (CacheHygieneService), DB integrity + dedup index
      + size, calibration anchored-vs-stale, savings.jsonl ingesting, disk/RAM
      thresholds. On-doctrine ("CFO/health cockpit that audits"); would have caught
      half this session's bugs (orphan leak, disk-full, stale exact).
- [ ] **TOON Phase 2** — opt-in replace of JSON tool outputs with TOON via
      `updatedToolOutput`, per-tool allowlist, lossless round-trip-or-passthrough.
      WAIT for `toon-potential.jsonl` data (Phase 1 measure-only is live) to prove
      the gain first. Design: `docs/design-toon-transpile.md`.
- [ ] **TOON readout UI** (Phase 1.5) — surface accumulated potential savings from
      `toon-potential.jsonl` in the Optimizer.
- [ ] **Circuit-breaker ACT** — auto-pause a runaway session before the cap.
      Predictive WARN already shipped (`ThresholdNotifier.forecastCapETA`). ACT is
      opt-in, warn-first, cancelable, reuse hibernation's SIGSTOP/CONT. Design:
      `docs/design-circuit-breaker.md`.
- [ ] **Xcode errors→claude** — 1-click button: parse newest build log/`.xcresult`
      in DerivedData, paste DISTILLED errors into the terminal (token-saving, local).
      Hard part = parsing `.xcactivitylog` (gzip SLF).

## Stats polish (small)
- [ ] Clarify the "/wk" figure is a *weekly projection* from the selected range
      (24h×7, 7d, 30d÷30×7) — users read 24h>30j as a bug; it isn't.
- [ ] Reset shows clock time → add an HH:MM countdown ("resets in 2h14").

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
