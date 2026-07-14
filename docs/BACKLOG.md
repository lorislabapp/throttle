# Throttle — backlog (deferred, as of 2026-06-27, post-3.2.16)

Nothing here is broken or urgent. These are deferred-on-purpose or on-demand.
Current shipped version: **3.2.65** (build 165) — SOTA sprint, 2026-07-14.

## Shipped 2026-07-14 (3.2.61→3.2.65) — offload one-click + SOTA sprint
Grounded in the adversarially-verified deep research `docs/research/sota-companions-2026-07-14.md`
(also NotebookLM source #220). Strategic memory: `anthropic-remote-control-threat.md`.
- [x] One-click SSH deploy of the edge agent (EdgeDeployService, pct-exec routing, zero paste)
- [x] In-app Claude login on the box (agent /auth/* drives `claude setup-token` through tmux)
- [x] Remote sessions in the rail w/ REMOTE badge; move semantics (local hibernates); bring-back
- [x] Mouse-report filter at the PTY chokepoint (SwiftTerm mouseMoved ignores allowMouseReporting)
- [x] ATS fix (NSAllowsLocalNetworking alongside ArbitraryLoads = ArbitraryLoads IGNORED) — Mac + iOS
- [x] SSH_AUTH_SOCK forwarded into cockpit PTYs (ssh-launched MCPs no longer prompt passphrase)
- [x] OAuth server-truth usage (api.anthropic.com/api/oauth/usage, keychain token) — primary Exact path
- [x] Cache-efficiency score (plan-yield %) on the Dashboard — the niche nobody occupies
- [x] Rules engine v1: pause Opus/Fable sessions past a token cap (default 200k)
- [x] Repo-on-the-box: offload ships a git bundle, agent clones it at the remote cwd (agent 0.6.0)

## Next sprint — Optimizer honesty pass (caveman research, 2026-07-14, verified)
Report: `docs/research/output-styles-caveman-2026-07-14.md` (NotebookLM source #222).
- [ ] **Brevity via hooks, not style**: UserPromptSubmit hook injecting a one-line "be brief"
      directive per turn (recency > system prompt) + SessionStart matcher "compact" re-injection
      after compaction. The style stays for NEW sessions; hooks carry the effect reliably.
- [ ] **Shadowing detector**: warn when a project's .claude/settings.local.json overrides the
      global outputStyle (silent Local > User precedence — /config writes there).
- [ ] **UI honesty**: after style/config writes, show "takes effect next session / after /clear";
      Optimizer savings claims capped at the measured reality (output = 9-15% of the bill;
      terse profile = -2 to -18% of OUTPUT only). Measure before/after via usage.db instead.
- [x] caveman-ultra.md: keep-coding-instructions: true (was already set), description corrected.

## SOTA gaps — decided NOT now / needs a decision (2026-07-14 research)
- [ ] **Multi-provider metering** (ClaudeBar does 11, CodexBar ~59): strategic dilution vs market — decide
      after offload traction. Observability-only if ever (doctrine: never a data-path proxy).
- [ ] **Review-and-merge layer** (Conductor's lane, $22M funded): out of scope — cockpit, not IDE.
- [ ] OAuth endpoint extras: per-model weekly (limits[].weekly_scoped), extra-usage spend surface.
- [ ] ❗Mid-session model right-size nudge is COUNTERPRODUCTIVE (per-model prompt caches) — only nudge
      at NEW-session/task boundaries. Corrects the earlier missed-opps list.
- [ ] Anthropic first-party Remote Control (research preview) erodes the iOS remote-control lane for
      subscription users; Throttle's residual niches: local→remote handoff (shipped), arbitrary-session
      observability, API-key/Bedrock users, cache-aware ops.

## Shipped 2026-07-08 (3.2.48 + 3.2.49) — web research MCP (local WebKit render + private grounding)
- [x] **Rank-1 `web_render`** (3.2.48) — renders a page's JS in an offscreen private WKWebView and
      returns the fully-rendered readable text (SPAs / client-rendered content native WebFetch misses).
      In-app `WebRenderer` + loopback bridge (:4319, loopback-only) + `--mcp-server` client; opt-in
      `throttleWebEnabled` + Settings toggle. SSRF guard, ephemeral cookie-less store, dialog-deadlock-safe.
- [x] **Rank-2 `research_grounded`** (3.2.48) — renders URLs AND cross-references the query against the
      user's locally-indexed repo corpus; retrieval+grounding only (synthesis stays the model's).
- [x] **Rank-3 render cache** (3.2.49) — `web_fetches` (migration v8) + ContentStore text cache; a repeat
      render within TTL is served from cache (no WKWebView). `useCache` param.
- [x] **`__web__` semantic recall** (3.2.49) — every rendered page is indexed into a synthetic semantic
      corpus, so research_grounded resurfaces prior research by meaning. Loopback-only bridge hardening.
- [ ] NOT built (deferred, low value): populate `web_fetches.session_id` for €-per-render join · screenshot
      in web_render (`takeSnapshot` → ContentStore) · a11y-tree snapshot (thin edge — claude-in-chrome's lane).

## Cockpit terminal — requested 2026-07-08 (Kevin)
- [x] **Focus routing on shell-open** (`6b69273`) — opening the side shell (or a tab whose shell just
      mounted) now focuses it once, async, on first mount only — never on later re-renders (that's what
      historically thrashed and auto-confirmed claude prompts). `MultiTerminalStack.updateNSView`.
      Build-verified; **still needs Kevin's live install+test** (this session runs IN the Cockpit — can't
      restart it to self-test, see [[dont-restart-throttle]]).
- [x] **A REAL Clear** (`6b69273`) — context-menu "Clear" now sends Ctrl-L *and* CSI 3J to wipe scrollback,
      so Ctrl-A/Select All shows nothing above the current command. No-op on claude's alt-buffer (no
      scrollback there); only bites the side shell / plain output. Build-verified; **needs Kevin's live test**.
- [x] **Copy CLI output optimized for Claude** (`70e7a5e`) — "Copy for Claude (trimmed)" context-menu item,
      reuses `TokoptHook.trimForCopy`.
- [ ] **Claude drives the terminal (plugin/add-on)** — let Claude/Throttle operate the terminal directly.
      Big design + doctrine call (agent-control vs measure-only cockpit); overlaps the side shell + Command
      Runner. Scope before building.

## Shipped 2026-07-08 (3.2.47, build 147) — RELEASED (notarized, appcast live, deployed)
- [x] **Two-tier auto-reclaim** — crowded-but-RAM-fine idle tabs now SIGSTOP-freeze
      (`autoPaused`, instant SIGCONT on focus, zero tokens, no `--resume` prompt)
      instead of hibernating; hibernate (kill → free RAM) only under real
      `machine.critical` pressure, and it escalates our own auto-paused tabs but never
      a user's manual pause. Fixes "my tabs keep dying and resuming costs tokens" when
      the Mac is merely crowded. `MultiCockpitModel.autoHibernateIfPressured` split by
      trigger; `notifyAutoPause`; rail tooltip.
- [x] **Output-style activation nudge** — `OutputStyleManagerSheet` green banner after
      tap-to-activate: the style only binds at session start, so run `/output-style`
      or `/clear` to apply it to an already-open session. Root cause of the months-old
      "caveman doesn't work" reports (it worked; it just needed a fresh session).
- [x] **Traycer** (opt-in) — local OTLP receiver (127.0.0.1:4318, http/json) →
      `traycer_events` (migration v7) joined on `session.id` to `usage_events` for true
      €-per-skill / €-per-command. E2e-verified against real Claude Code 2.1.204 OTLP
      (decoder 5/5, store 3/5, migration green). Env installer merges the OTLP keys
      into settings.json (reversible, no prompt logging).
- [x] **Test-infra fix** — stopped double-linking GRDB into ThrottleTests (`link: false`),
      which had been fatal-trapping every DB test suite. Full suite now 157/0.

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

## Built 2026-07-02 (3.2.37) — eval-driven test-outcome signal (NotebookLM missed-opp #5)
- [~] **"Cost per outcome" — detection half DONE.** `TestOutcomeDetector` parses
      pytest/cargo/go/jest/swift-test summaries out of the PTY stream (via the existing
      DroppableTerminalView sniff, dedup by value + 2-min floor); `TestOutcomeStore`
      logs green/red counts per project to `test-outcomes.jsonl`; `EvalReadout` shows
      pass-rate + green/red runs (14d) in the Optimizer tab, measure-only. Unit-tested
      (TestOutcomeDetectorTests, 9 cases incl. prose false-positive guard). GAP left:
      joining each run to its exact token cost for a true "€/green run" — needs a cost
      snapshot at outcome time (StatsDataService.cockpitSessionCostEUR) threaded through;
      deferred until the pass/fail signal proves useful. Pure measure-only, in-doctrine.

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

## Verified 2026-07-12 — ready to scope, not yet built
- [x] **MEMORY.md 200-line cap audit / segmentation** — premise CONFIRMED true
      (docs.claude.com/memory, "How it works"): `MEMORY.md` auto-load silently
      truncates at 200 lines / 25 KB; content past that never reaches context.
      `CLAUDE.md` is NOT truncated — loaded in full regardless of length (200 lines
      is only a soft readability guideline there). So the feature should scope to
      `MEMORY.md` only: a hard-cap warning/segmentation when a user's memory dir
      pushes `MEMORY.md` past 200 lines, distinct from any softer CLAUDE.md nudge.
      Autopilot already archives stale/orphaned memory — this would be the sibling
      check for "memory that's still live but the index itself overflowed."
      BUILT 3.2.57 (warn half): `HealthCheckService.memoryIndexCap()` scans every
      project's `memory/MEMORY.md` for >200 lines / >25 KB and warns in Throttle
      Health with the offending projects. Auto-segmentation deliberately NOT built
      (rewrites live memory content — user's call per doctrine).
- [x] **Session Offload with context transfer (full-copy + resume)** — premise
      VERIFIED live 2026-07-12: copied a session JSONL into
      `~/.claude/projects/<encoded-new-cwd>/` and `claude --resume <id>` from that
      different cwd recovered the full context (old internal cwd fields don't
      break resume). Closes the offload design gap: today "send to server" spawns
      a FRESH claude (context rebuild = 10–20 turns / 15–30 min of token burn,
      contradicting the wedge). Recipe: Mac copies the session JSONL to the box
      at `~/.claude/projects/<encoding of remote cwd>/` (scp emitted-script style,
      app never SSHes → emit the copy command for the user, or do it via the
      agent's HTTP API with an upload route), then `POST /sessions` with the
      existing `resume` param (`EdgeAgentService.start` already passes it;
      `throttle-agent.mjs` already launches `claude --resume`). Constraint per
      `throttle-dag-fork-deferred`: FULL copy of the JSONL only, never truncate —
      truncation corrupts the session chain. Single-session offload stays; no
      mass offload (complexity, doesn't serve the wedge).
      BUILT 3.2.57: agent 0.3.0 `PUT /transcripts` (streamed to disk, 512 MB cap,
      session-id regex + encoded-cwd guard, route-tested live with curl);
      `EdgeAgentService.uploadTranscript`; `RemoteSessionsService.offload` +
      `recentLocalSessions()` (pure FS scan); SessionOffloadSheet picker +
      "Offload with context" button + status line.

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
