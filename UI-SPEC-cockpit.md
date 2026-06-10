# UI-SPEC — Cockpit window

The cockpit is a resizable macOS window (default 900×600, min 640×400) that embeds a
real `claude` terminal (`SwiftTerm.LocalProcessTerminalView`, always dark) wrapped by
Throttle's **decision layer**. The terminal is a commodity container; the product is the
instrument around it. Inherits the locked "precise cockpit" language (flat sections,
full-bleed hairlines, graphite, mono tabular digits, accent for interactive only, colour
ONLY under at-cap pressure, exact-vs-estimate degradation, PRO/FREE/EXACT pills, NO
Canvas/numericText/shadow — hand-rolled `Path`/`Shape`).

Source of truth: `Throttle-7-export/cockpit.css` + `cockpit-components.jsx` + `cockpit-directions.jsx`.

---

## Chosen direction — "one cockpit, two density levels + a focus mode"

A and B both carried the binding hero, so they are **role-split** (no redundancy):

| Level | Chrome | Carries | Toggle |
|---|---|---|---|
| **Full** (default) | top **strip (A)** + collapsible right **rail (B)** | strip = the *decision*; rail = the *detail* | rail collapses via panel icon |
| **Compact** (focus) | ambient **HUD chip (C)** overlaid on terminal | binding only, grows/colours under pressure | "focus" toggle hides strip+rail |
| *(later)* Prompt gauge (D) | powerline segment **inside the shell prompt** | binding % + time-to-cap | opt-in shell PS1 integration, NOT v1 |

- **Strip (A)** owns the 3 decision numbers: `BINDING NOW` hero · `FORECAST` nudge · `THIS SESSION` cost.
- **Rail (B)** owns the **environment & cost sources** (the things you act on): `OTHER WINDOWS` · `MODEL SPLIT` · `MCP HEALTH` · `CONFIG WEIGHT`. Collapsible.
- **Compact (C)** is a `ZStack` glass overlay, top-right of the terminal — trivial and faithful.
- **D is out of v1** (needs shell-prompt integration, not SwiftUI chrome).

---

## Layout & hierarchy

```
┌─ titlebar (38pt) ─ lights · gauge+"Throttle Cockpit" · ~/path · [spacer] · Concise · panel⌹ · PRO/EXACT ─┐
├─ AtLimitBanner (only when binding ≥80%) ──────────────────────────────────────────────────────────────┤
├─ A-strip (64pt) ── BINDING NOW │ FORECAST (flex) │ THIS SESSION ───────────────────────────────────────┤
│                                                                          │  B-rail (232pt, collapsible) │
│   ████ terminal (SwiftTerm, dark, flex fills) ████                       │   OTHER WINDOWS              │
│                                                                          │   MODEL SPLIT               │
│                                          ┌─ HUD chip (compact mode only) │   MCP HEALTH                │
│                                                                          │   CONFIG WEIGHT (optimize)  │
└──────────────────────────────────────────────────────────────────────────┴──────────────────────────────┘
```

The rail is **"Environment & cost sources"**, not a post-mortem dashboard — every section is something a power user *acts on* mid-flow (kill a zombie MCP, trim CLAUDE.md, switch off Opus), so it earns staying open. Session-history bars were dropped (low daily ROI; lives in Stats).

- Vertical: titlebar (38) → [banner] → strip (64) → terminal (flex). Rail spans strip-bottom→window-bottom on the right, `borderLeft` hairline.
- Compact mode: hide strip + rail; terminal full-bleed; HUD `ZStack` top-trailing inset 12.

## Spacing scale
- Titlebar: height 38, padding H 14, gap 10; right cluster gap 9.
- A-strip: minHeight 64. Cells padding 11×16, intra-cell gap 7. `A-cell + A-cell` = `borderLeft` hairline. hero minWidth 168, nudge `flex:1`, cost minWidth 150.
- B-rail: width 232, `borderLeft` hairline. `B-sec` padding 14×16, `+B-sec` = `borderTop` hairline. label marginBottom 10.
- HUD: inset 12,12. padding 9×12 (neutral) → 12×14 (warn/crit). gap 7. minWidth 116 → 188 (warn) → 196 (crit). radius 11.
- AtLimitBanner: padding 9×14, gap 10.

## Corner radii
- Window 11 · pills 5 · HUD 11 · bars/capsules 2–3 · concise switch 9 (knob 7).

## The ONE accent
- `accent` (= app accent, `#0071E3`-family) used ONLY for interactive/links: the `Switch model` action in AtLimitBanner, concise toggle ON state. Never for data.
- Pressure colours are NOT the accent: `warn` = orange/amber, `crit` = red. Applied ONLY at ≥80 / ≥95.
- Everything else graphite: `ink / ink-2 / ink-3` (primary / secondary / tertiary).

## Type roles
- Binding hero %: mono tabular, weight ~560, letterSpacing -0.03em. **Strip 30pt**, rail 38pt, HUD 22pt. `%` sign = 0.5em, opacity .55. `≈` prefix (`.approx`, ink-2) when estimate.
- `dl-label` (section labels BINDING NOW / FORECAST / …): 9.5pt, weight 660, tracking 0.08em, UPPERCASE, ink-3.
- bind-name 11.5pt/560 ink, `.sub` ink-2 normal; bind-reset 10.5pt ink-3 (mono for the time).
- Nudge value `.nv` mono/560; body 12pt ink-2. Cost value mono/560 ink, label 10.5pt ink-3.
- `est` tag: 9pt, hairline inset box, lowercase.
- Terminal: mono 12pt, line-height 1.62, palette `#161618` bg / `#D4D4D8` ink / green `#4EC9A0` prompt / blue `#6AA6F0` tool / purple `#B98BE0` file / amber `#D8A24A` sys.

## Component inventory + states
1. **CockpitTitleBar** — traffic-lights (decorative; real window has native), gauge glyph + "Throttle Cockpit" + mono `~/path`, spacer, `ConciseToggle`, panel-toggle icon (rail show/hide), `StatusPills`.
2. **StatusPills** — `PRO`|`FREE` always; `EXACT` (solid, with dot) only when `confident && pro`. Reuse app's pill style.
3. **BindingHero** — `{≈}{pct}%` + name/sub + "resets `{time}`". Tone class: estimate→muted(ink-2), else neutral/warn/crit. The binding = window closest to cap (max pct).
4. **HeadroomBar** — track + fill to pct; ticks at 80% & 95%; fill warn/crit by tone; estimate → hatched (`repeating-linear-gradient -45°`, opacity .8). Strip width 150.
5. **PredictiveNudge** — clock icon (calm) / warn-triangle (warn·crit); `"{time} · {msgs} msgs {text}"`; `est` tag when not confident. Tone tints icon+values.
6. **SessionCost** — `{tokens} tok · {eur}` + caption `this session · {allEur} all-time`. Stacked in strip & rail.
7. **MiniWindows** (rail "Other windows") — the non-binding windows: name · 4pt bar · `{≈}{pct}%` (muted when estimate). grid `1fr 64 30`.
8. **ModelSplit** (rail) — segmented bar (m1 ink70% / m2 ink40% / m3 ink18%) + label `{top model} {pct}%`. >70% Opus → amber hint (cost signal, not at-cap pressure).
9. **MCPHealth** (rail) — one row per MCP server from `~/.claude.json` / `.mcp.json`: name · status dot (ok / degraded / zombie) · `p50`ms. Status from a background `list_tools` JSON-RPC probe (not a TCP ping); schema-drift = hash change vs last probe. A zombie MCP loops the agent and burns the 5h window → this is on-wedge, not telemetry-for-telemetry. Probes are throttled + backed-off; never spam-restart. Omit the whole section if no MCP config is found.
10. **ConfigWeight** (rail) — token cost of the local context sources, read locally: `CLAUDE.md` (k tok) · `N skills` (k) · `N MCP` (k) · stale memory files. Each row has a `Optimize` affordance (accent) that hands off to Throttle's existing AI assistant/optimizer (diff-preview + rollback) — Throttle already audits `CLAUDE.md`/`settings.json`; this extends it to skills/MCP. Reference weights for copy: CLAUDE.md 5–10k/session, MCP 2–10k each, skills up to 20k, memory files often stale.
11. **CompactionGauge** (strip/forecast-adjacent) — when the *active session's* context approaches the ~70% auto-compaction threshold, surface a calm inline cue: `"Context ~70% — /clear before the next reply saves ≈20–30k tokens"`. LocalTracker already counts per-session tokens; this is a threshold trigger, not a new feed. Highest ROI / lowest effort decision-layer add.
12. **AtLimitBanner** — appears only when binding tone ≠ neutral. warn-soft/crit-soft bg, warn/crit triangle. Text: crit = `"{name} {sub} cap in {time} at this burn — finish up or switch to Sonnet."`; warn = `"Approaching {name} cap — {time} left at this burn rate."`. Trailing `Switch model` action (accent).
13. **HUDChip** (compact) — glass `rgba(22,22,24,.72)` + blur; name label, big mono %, thin bar, nudge line (hidden at neutral, shown at warn/crit), cost line. Grows + colours by tone. **Ships day-one** (the mode that survives power-user scrutiny), not a later add.
14. **CockpitTerminalView** — existing SwiftTerm host. Unchanged.

### States (drive every component)
- **headroom** (neutral): no banner, all graphite, HUD small/quiet.
- **approaching** (warn ≥80): banner warn, hero/bar/nudge amber, HUD grows amber + nudge shown.
- **atcap** (crit ≥95): banner crit, red, HUD 196 red + nudge; binding flips to the weekly window when it's the closest to cap.
- **estimate** (degraded, `!confident`): `≈` prefixes, hero muted, bar hatched, `est` tags, NO EXACT pill.
- **free**: FREE pill, no EXACT, estimate styling.

## Motion (respect `reduceMotion`)
- Rail collapse/expand: width 232→0 ease (cubic-bezier .22,.61,.36,1, ~0.22s). One moment.
- HUD grow/recede on tone change: size+colour transition ~0.3s. Bars fill 0.6s. Under `reduceMotion`: no width/size animation, snap.

## Accessibility
- Hit targets ≥44pt: panel-toggle, concise toggle, `Switch model` get ≥44pt tap area (`.contentShape`).
- VoiceOver: hero reads "Binding: Weekly all models, 97 percent, estimate" ; nudge reads full sentence ; banner is an `.isModal`-free announcement (`accessibilityAddTraits(.updatesFrequently)` on the strip).
- Contrast: pressure colours only on ≥ AA pairings; graphite ink-3 not used for essential-only text.
- Dynamic Type: chrome text scales; terminal is fixed mono (user controls via terminal font).

## macOS 26.5 guardrails
- NO `Canvas`, NO `.contentTransition(.numericText)`, NO `.shadow` in this window's SwiftUI chrome.
- History bars + headroom bar + model split = `Capsule`/`RoundedRectangle`/`Path` only.
- HUD blur via `.background(.ultraThinMaterial)` (dark), not a custom shadowed layer.
- Window keeps the `.accessory → .regular` activation-policy trick (already in `CockpitWindowController`).

## Non-goals (explicit — refuse on sight)

The wedge is **the decision layer around the local agent**, validated NARROW-SCOPE GO. Anything that turns the cockpit into a terminal/IDE or breaks the "everything stays on your Mac" privacy USP is out:

- **No third-party service integrations** — GitHub PRs/issues/CI, Jira, Linear, cloud anything. They make us a worse IDE, kill the privacy story (accounts/OAuth/network), and have zero cost/usage angle. Code-host = GitHub; editing = VS Code/Warp.
- **No general-terminal features** — tabs, splits, themes, SSH, profiles, prompt customization. SwiftTerm stays a commodity container.
- **No cloud sync / accounts** beyond the existing offline license check.
- **Allowed because it's LOCAL, not an integration:** per-repo cost attribution reads `~/.claude/projects/<repo>/` only — "this repo cost X tokens this week" is on-wedge; calling the GitHub API is not.

The filter for every cockpit feature: *does it stop the user hitting the 5h/weekly cap unwarned, or cut their tokens?* If no → out.

## Possible follow-up (not v1): global floating HUD

The biggest strategic risk is the "SwiftTerm prison" — power users won't abandon Warp/Ghostty. The HUD (compact) is the part that survives. A later option worth prototyping: the HUD as a **borderless always-on-top `NSPanel` floating over any terminal**, decoupled from the embedded SwiftTerm — so the decision layer reaches users who never adopt our terminal. Out of v1 scope; noted so the HUD is built decoupled enough to lift out later.

## Implementation map (files)
- `CockpitWindowRoot.swift` — replace the current thin strip with: `CockpitTitleBar` + `AtLimitBanner?` + `CockpitStripA` over `HStack { CockpitTerminalView ; if railOpen { CockpitRailB } }`, with a `@State mode: .full/.compact` and `@State railOpen`. Compact → `ZStack { terminal ; HUDChip }`.
- New `Throttle/UI/Cockpit/CockpitComponents.swift` — the primitives above (pure SwiftUI, reuse existing pressure/pill helpers from the meter where they exist). Keep `HUDChip` self-contained (no dependency on the window chrome) so it can later be lifted into a floating `NSPanel`.
- Data: bind to real `appState` — `exactSnapshot` (exact) else `snapshot` (local) for the windows; binding = max pct; cost/split from existing services (PlanAdvisor/StatsDataService/ExactModeService). MCP health + config weight read `~/.claude.json`/`.mcp.json`/`CLAUDE.md`/skills locally. Where a real feed doesn't exist yet (msgs-left forecast, p50 latency), surface only what's real and omit the rest — never fake a number.
- Run `xcodegen generate` after adding `CockpitComponents.swift` (sources globbed).
