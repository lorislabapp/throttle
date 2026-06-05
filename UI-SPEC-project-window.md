# UI-SPEC — Throttle Project window (Direction A · "Sidebar + Tabbed Detail")

Chosen via Claude Design (2026-06-05). The one real macOS window (~860×540,
resizable), opened via `ProjectWindowController` → `ProjectWindowRoot`. Inherits the
cockpit tokens at window scale. Direction A == the structure the window already had,
so this was a restyle, not a re-architecture.

## Layout
- Header strip: back · gauge · "Throttle" · PRO/FREE pill. (The NSWindow provides the
  traffic-light titlebar.)
- Body split: **Sidebar (220pt)** | **Detail**.
  - Sidebar: flat search field · "RECENT" section · rows (dot · name · recency,
    selection = soft fill + hairline) · "Include archived" footer toggle.
  - Detail: **detail header** (project name + mono path + Reveal in Finder) · **tab bar**
    (Stats / Files / Optimizer / Assistant — accent text + 2pt underline, lock glyph on
    the two Pro tabs) · scrolling content.

## Tabs
- **Stats (hero, free)**: bordered usage grid (This week / This month / Sessions / API
  cost, mono) + graphite weighted model split + API-equiv/mo footer. Per-project daily
  trend chart is NOT built (no per-project daily query yet) — follow-up.
- **Files (free)**: flat rows (doc · mono name/path · size/mod · Reveal/Open), hairline-
  divided; CLAUDE.md / settings.json / settings.local.json + project root.
- **Optimizer (Pro)** + **Assistant (Pro)**: cockpit `proLockPlaceholder` when free
  (lock · "<tab> is a Pro feature" · feature chips · Upgrade · €19). The Pro *internals*
  of these two tabs (`ProjectOptimizerTab`, the 950-line `ProjectAssistantTab`) keep
  their current styling for now — restyle is a follow-up.

## Tokens
- Mono tabular digits for tokens/%/€/sizes/dates. Hairlines + 22pt detail padding /
  ~12pt sidebar. Accent (system blue) on interactive/links only; graphite model split
  (ink 72/42/20%). No Canvas/numericText/shadow (macOS 26.5); model bar is plain fills.

## States: populated project · Pro-locked Optimizer/Assistant · no project selected
(`emptyState`) · no projects yet. Wiring preserved (ProjectsService, StatsDataService,
file URLs).
