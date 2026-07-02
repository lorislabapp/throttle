# Throttle — backlog (deferred, as of 2026-06-27, post-3.2.16)

Nothing here is broken or urgent. These are deferred-on-purpose or on-demand.
Current shipped version: **3.2.16** (build 116).

## Built 2026-06-30 — v3.0 chantiers (3.2.21, COMMITTED, NOT yet released — deploy blocked on notarization)
- [x] **C1 tokopt test-runner recipe** — cargo/go/swift/pytest/jest green-run collapse, self-safe verbatim on failure.
- [x] **C2 CMV reversible pointers** — SHA-256 `ContentStore` + trimmer pointers (apply/snapshot-only persist) + `throttle_expand_pointer` MCP tool.
- [x] **C2 DeltaMem** (residual Root+Delta graph) + **OKF v0.1** bundles + `throttle_recall` MCP tool + `importOKF` bridge.
- [x] **C4 edge vector RAG (Throttle-native)** — `VectorStore`/BruteForce + `EmbeddingProvider`/NLEmbedding + `SemanticIndex` + `RepoIndexer` (incremental) + `SemanticCorpusStore` + `--index-repo` CLI + `throttle_semantic_search` MCP tool.
- [x] T2 proxy `protocolVersion` echo · T3 dead-MCP token-tax · dropdown reset countdown · fix stale calibration test.
- ⚠️ The 4 new MCP tools (`expand_pointer`/`recall`/`semantic_search`) only surface after a Throttle restart (reloads `--mcp-server`).

## Built 2026-07-02 (3.2.35) — CMV auto-trim + NotebookLM-driven hardening
- [x] **Auto-trim idle transcripts (opt-in)** — `ContextTrimmerService.autoTrimIdle`
      + launch hook (`throttleAutoTrimEnabled`, default OFF) + Settings row + silent
      `notifyAutoTrim`. Reuses the existing lossless+reversible `apply` path; 10-min
      idle floor (`minIdleSeconds`) so a session you're resuming is never touched.
      The manual trimmer shipped 3.2.21 but nobody benefited — this makes it automatic
      without crossing doctrine (structurally lossless, backed up, pointers rehydrate
      via `throttle_expand_pointer`). NotebookLM's #2 missed-opportunity, done in-doctrine.
- [x] **Post-write byte-verify in the trimmer** — `apply` now reads the file back and
      restores the backup + aborts on any round-trip mismatch (FileEditor-style).
- [x] **State-aware `pauseIdleSessions`** — routed through `drainThenPause` so the
      pacing banner's "Pause idle" can't SIGSTOP mid-flight (NotebookLM Q2 catch).
- [ ] NOT built (lossy / crosses doctrine): orphaned-tool_result removal, structural
      block/turn dropping, retrieval-time semantic dedup proxy, AST diff interception.
      NotebookLM flagged these as higher-savings but they silently change the model's
      inputs or become a data-path proxy — parked behind explicit consent + real
      before/after task-success measurement.

## Deferred from the v3 build (DON'T FORGET)
- [~] **C4 native vector engine** — DONE the safe/native part 2026-07-01: BruteForce cosine now uses **Accelerate/vDSP** (`vDSP_dotpr`/`vDSP_svesq`, SIMD on Apple Silicon, zero deps / zero C-ext / zero signing). STILL DEFERRED (premature for single-dev scale, fork): a true ANN backend (sqlite-vec C-ext — bundle+sign risk — vs Wax Swift-native young dep) + ANE embeddings (bge-small / CoreML / MLX), both behind `VectorStore`/`EmbeddingProvider`. Revisit at 100k+ vectors.
- [x] **Semantic auto-indexing** — DONE 2026-06-30: `SemanticAutoIndexer` (off-main, opt-in, memory-pressure-gated, incremental over project roots) + launch wiring + Settings toggle ("Semantic project index"). Makes `throttle_semantic_search` usable without manual `--index-repo`.
- [x] **Deploy 3.2.21** — SHIPPED 2026-07-01: notarized + stapled + Sparkle-signed + appcast updated + full `deploy.mjs`. Verified live (appcast top 3.2.21, DMG 200, content-length matches signed length). Notarization had timed out repeatedly on the beta Mac (env) then went through on retry.

## Shipped since 3.2.2 (→ 3.2.15, 2026-06-27)
- [x] **Pattern-A proxy** — Streamable-HTTP MCP front (`Throttle --mcp-proxy`) owning
      the downstream stdio server; respawns it prefix-stable without busting the prompt
      cache. CORE + FRONT + **proactive health monitor** (15s ping → respawn zombie
      before a real `tools/call` hits it). VERIFIED end-to-end 2026-06-27 against
      Claude Code's real HTTP MCP client (`claude -p --mcp-config --transport http`):
      client connected + listed tools + called a tool through the proxy; froze the
      downstream (SIGSTOP zombie) → monitor respawned it → a 2nd real `claude` call
      succeeded via the respawned child. No longer an open risk.
- [x] **Focus Filter (quiet mode)** + interactive widget **Pause** + `pause`/`quiet`
      URL scheme.

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
- [x] **Auto-pause (true ACT)** — SHIPPED (found wired 2026-06-30): `evaluateAutoPause`
      ticks each cycle; ≥95% binding + derived burn-ETA <5min + a live burning session
      → cancelable 10s countdown → `drainThenPause` (quiescent-window SIGSTOP, targets
      the looping session only). Opt-in `throttleAutoPauseEnabled`, Settings toggle
      "Auto-pause near the cap", banner + Cancel in MultiCockpitRoot. Never a hard kill.
- [x] **Rate-limit pacing/Retry-After** — DONE 2026-07-02 (3.2.33). Predictive
      CROSS-SESSION pacing shipped: `evaluatePacing()` + soft banner tier BELOW
      auto-pause — when the binding window is in [80%, 95%), rising, ETA-to-cap
      ≤30 min AND ≥2 sessions actively burning, a non-destructive banner warns
      "N sessions burning — ≈Xm to your cap" with a one-tap "Pause idle"
      (`pauseIdleSessions()`, reversible SIGSTOP of live-but-not-working, non-focused
      sessions). Retry-After half was already effectively covered: `ExactModeService.
      pollPolicy` honors each window's `resets_at` (Retry-After-equivalent) + expo
      backoff on failure, and `ClaudeWebSessionProvider` handles hard 429 + resetsAt.
- [ ] **TOON Phase 2 → CCR (Compress-Cache-Retrieve)** — upgraded target (NotebookLM
      2026-06-20): a `PostToolUse` hook replaces verbose low-signal tool output with
      a ~50-token pointer + stashes the raw text in a local SQLite cache; a bundled
      `throttle_expand(hash)` MCP tool lets claude pull it back on demand. HARD no-op
      on failures/stderr/stack-traces/JSON the model needs. WAIT for `toon-potential.
      jsonl` data to confirm the gain before ship. Design: `docs/design-toon-transpile.md`.
      NB — do NOT conflate with the **tokopt-bash trimming** that IS live (strips
      headers/hints/ANSI from `git status` etc., logs realized savings to
      `savings.jsonl` via `TokoptHook`). Any doc claiming "CCR shipped, ~53% proven"
      means that trimming, NOT this array→TOON transpile, which is unbuilt.
- [~] **Read-Firewall / local-RAG auto-config** — DETECTION HALF DONE 2026-07-02
      (3.2.34). `ReadFirewallScanner` scans a project's 14d transcripts for the
      brute-force signature (≥3 `Read`s in one turn; best-effort re-read attribution)
      → `ReadFirewallReadout` (measure-only strip in the Optimizer tab: heavy turns,
      file reads, "mostly <file> ×N"). The **auto-inject half is deliberately NOT
      built**: semantic recall is lossy, so silently rewiring `.mcp.json` changes what
      the model sees (golden-rule-adjacent) — the readout nudges, the fix stays the
      user's. `mcp-local-rag` was also removed in the MCP cleanup (0 real calls), so
      auto-wiring it is moot. Revisit only if a reliable local-RAG + before/after
      task-success measurement lands. Design: `docs/design-read-firewall.md`.
- [x] **TOON readout UI** (Phase 1.5, done 2026-06-27) — `TOONPotentialReadout` in the
      Project Optimizer tab folds `toon-potential.jsonl` via `TOONTranspiler.potentialSummary()`
      (≈% / ≈bytes / ≈tokens / sample count, measure-only, hidden when empty). Still
      collecting data — no samples on the dev Mac yet, so TOON Phase 2 stays gated.

## Stats polish (small)
- [x] Reset shows clock time → countdown added to the menu-bar dropdown too
      (3.2.21: "resets 9pm (in 2h 14m)" on hero + secondary rows, via
      `MultiCockpitModel.countdown`; cockpit binding already had it).

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
