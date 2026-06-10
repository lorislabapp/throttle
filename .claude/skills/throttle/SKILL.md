---
name: throttle
description: Apply for any work in the Throttle repo (macOS menu-bar Claude Code usage meter + the Cockpit). Load before touching usage data, the cockpit, Stats, Exact mode, licensing, or the build. Carries the product wedge + non-goals, the data model (UsageSnapshot/ExactSnapshot/AppState/StatsDataService/PlanAdvisor), the DB schema + weighted-token formula, the cockpit design language, macOS 26.5 guardrails, and the XcodeGen workflow — so sessions don't re-discover them.
---

# Throttle — project architecture

macOS menu-bar app that tracks Claude Code usage across 3 windows (Session 5h,
Weekly all, Weekly Sonnet) + the **Cockpit** (a real `claude` terminal wrapped
by the decision layer). Repo: `~/GitHub/Throttle`. Swift 6 strict concurrency,
SwiftUI + AppKit, macOS 14+, GRDB, XcodeGen. Publisher Christine Martin (TDV6D5L785).

## Product doctrine (don't drift)
- **Wedge = cockpit-around-the-agent, NOT a terminal.** Verdict: NARROW-SCOPE GO.
- **Moat = the decision layer** Anthropic's dashboard doesn't surface: binding number, predictive cap nudge, per-session/config cost.
- **Non-goals (refuse):** tabs/splits/themes/SSH/profiles (Warp's turf), GitHub/third-party/cloud/accounts (kills the "everything stays on your Mac" USP). Per-repo cost is OK because it reads local `~/.claude/projects/<repo>/`, never the GitHub API.
- **Filter for any feature:** "does it stop the user hitting the 5h/weekly cap unwarned, or cut their tokens?" If no → out. Pattern: detect → cost-attribute → optimize 1-click.
- **Golden rule — never render a faked number.** A value you can't stand behind is degraded (`≈` prefix, muted tone, `est` tag, EXACT pill hidden) or the cell is hidden. EUR figures are **API-equivalent value**, not subscription spend — label them.

## Data model (this is what gets re-discovered — use it)
- `AppState` (`State/AppState.swift`, `@MainActor @Observable`): `snapshot: UsageSnapshot`, `exactSnapshot: ExactSnapshot?`, `exactModeEnabled`, `savedTokensThisWeek/ByDay/Today/Yesterday`, `isPro`, `claudeCodeDetected`, `database: any DatabaseWriter` (GRDB). Methods `refresh()`, `markFirstRunDone()`, `setExactModeEnabled(_:)`, `refreshProStatus()`.
- `UsageSnapshot` (`State/UsageSnapshot.swift`): `session5h / weeklyAll / weeklySonnet : Window`, `computedAt`, `hasAnyData`. `Window { kind: WindowKind, usedTokens, capTokens: Int?, resetInSeconds: Int64, var percentUsed: Double? }`. Local JSONL math.
- `ExactSnapshot` (`State/ExactSnapshot.swift`): `fiveHour / sevenDay / sevenDaySonnet : Window { utilization: Int /*0-100*/, resetsAt: Date? }`, `fetchedAt`, `isFresh(now:tolerance:)` (default 10 min). Server-true, scraped from `claude.ai/settings/usage` via Safari/AppleScript.
- `StatsDataService` (`Services/`): `Range {.last24h/.last7d/.last30d/.all}`, `modelSplit(in:range:) -> [ModelSlice{tier: ModelTier, weightedTokens}]`, `extrapolatedCostEUR(in:range:)`, `tokensBetween`, `tokensForProject`, `modelSplitForProject`. `ModelTier {.opus/.sonnet/.haiku/.other}`. Rates: Opus $15/$75, Sonnet $3/$15, Haiku $0.80/$4 per M; cache write 125% input, cache read 10% input; USD→EUR 0.93.
- `CockpitQueries` (`Services/`, extension `StatsDataService`): `cockpitCurrentSessionId`, `cockpitSessionTokens/CostEUR/MessageCount`, `cockpitModelSplitForSession`, `cockpitRecentBurn` (15-min global sample), `cockpitRecentSessions`, `cockpitCurrentModel`, `cockpitSessionPath`.
- `PlanAdvisor` (`Services/`): `opus47/sonnet46/haiku45 = ModelRate(inputPerM, outputPerM)` (13.80/69, 2.76/13.80, 0.74/3.68), `recommend()`, `ladder()`, `fit()`. **No burn-rate/forecast** — that's computed in the cockpit from `cockpitRecentBurn` + the binding window's cap.

## Database (GRDB)
`~/Library/Application Support/Throttle/db.sqlite`.
- `usage_events`: `session_id`, `timestamp` (Int64 epoch), `model`, `input_tokens`, `output_tokens`, `cache_create`, `cache_read`, `service_tier?`. **Weighted tokens = `input + output + cache_create + (cache_read / 10)`** (consistent everywhere).
- `usage_snapshots`: `timestamp_bucket`, `window_kind`, `used_tokens`, `cap_tokens` (time series).
- `file_state`: `path` (the session JSONL path; `session_id` is the filename stem) — join here to map a session → project.
- `tokopt_savings`: RTK hook savings.
Read off-main: `try await database.read { db in … }`, return `Sendable` structs (never live `Row`/`Database`).

## Ingestion
- `LocalTracker`: parses `~/.claude/projects/*/conversation.jsonl` every ~10s → `usage_events`.
- `ExactModeService`: AppleScript drives Safari to `claude.ai/settings/usage` every ~5 min (apple-events entitlement; sidesteps a macOS 26.5 WKWebView font crash).
- Config files: MCP servers in **`~/.claude.json`** (`mcpServers`) + `~/.claude/settings.json`; `~/.claude/CLAUDE.md`; `~/.claude/skills/`; `~/.claude/hooks/` (`session-start-router.sh` writes savings + reads the `~/.claude/throttle-concise` flag).

## Cockpit (`Throttle/UI/Cockpit/`)
- `CockpitWindowController` — NSWindow with the `.accessory → .regular` activation-policy trick (dodges the macOS 26.5 NSTitlebar crash when a menu-bar app makes a titled window); flips back on close.
- `CockpitWindowRoot` — **full** (Strip A: BINDING/FORECAST/SESSION + collapsible Rail B: other windows / model split / config weight / MCP / recent sessions) and **compact** (ambient HUD over full-bleed terminal). Toggles for rail + compact.
- `CockpitTerminalView` + `CockpitTerminalController` — SwiftTerm `LocalProcessTerminalView`, spawned via the user's **login shell** so PATH + secrets load; `controller.run("…")` types a command (Resume = `claude --resume <id>`, model switch = `/model <name>`) — passthrough, no session store, one terminal, no tabs.
- `CockpitData` + `CockpitViewModel` (10s off-main loader) + `ConfigWeight.read()`; `MCPHealthService` (on-demand `list_tools` probe via login shell; remote = HEAD only, never spawned).

## Design language ("precise cockpit", every surface)
Flat sections, full-bleed hairlines (`Color.primary.opacity(~0.09–0.10)`), no floating tinted cards. Graphite by default; mono **tabular** digits for every number. Single accent **system blue (#0071E3) for interactive/links ONLY**, never data. Pressure colour **earned**: orange ≥80%, red ≥95%, only under real cap pressure. Confidence outranks size: exact = crisp; estimate = `≈` + muted + `est` tag + no EXACT pill. Pills: PRO soft / FREE outlined / EXACT inverted-solid+dot. Specs in repo: `UI-SPEC-{meter,stats,settings,onboarding,project-window,cockpit}.md`; decision logs in `docs/cockpit-*.md`. (Strategy/research lives in the NotebookLM "Throttle - Documentation" notebook.)

## macOS 26.5 guardrails (hard)
In menu-bar popovers / cockpit chrome: **NO `Canvas`, NO `.contentTransition(.numericText)`, NO `.shadow`** (RenderBox/Metal regression). Bars/charts hand-rolled with `Path`/`Shape`/`Capsule`/`RoundedRectangle`. Materials via `.background(.ultraThinMaterial)`.

## Build & infra
- **XcodeGen**: `project.yml` globs `sources: - path: Throttle`. After **adding or deleting any file**, run `xcodegen generate` or the build won't see it. The `.xcodeproj` is regenerated/gitignored.
- `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`, `MARKETING_VERSION 3.0.x`. SwiftTerm via SPM.
- **Not sandboxed** (hardened runtime only) — reads `~/.claude`, AppleScript Exact mode, writes flag/log files. `ThrottleWidget` extension IS sandboxed; data crosses via an App Group. Bundle prefix `com.lorislab.`
- **App Store is off the table** (the terminal spawns a process). Distribution = Developer ID notarize + Sparkle + Stripe/MoR.
- Build check: `xcodebuild -scheme Throttle -configuration Debug -destination 'platform=macOS' build`. SourceKit may show false "cannot find type" errors for cross-file types — trust the xcodebuild result.
- Commit convention: `[throttle] action: description`. Avoid backticks/`<>`/`>` in `-m` (zsh evaluates them).
