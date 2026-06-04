# UI-SPEC — Throttle meter dropdown (Direction B-hybrid)

Chosen direction (Claude Design, 2026-06-04): **B — The Binding Number**, grafted with
A's legible secondary rows and C's danger-zone bar language. Stance: **precise cockpit**.
Theme: **light + dark**, both first-class.

## Principle
The *binding* window — the one closest to its cap — is the number that decides
whether to keep going. It is the hero. The other two recede. **Emphasis follows
risk**: when Sonnet crosses Session, the hero swaps automatically.

**Confidence outranks size.** If the binding window is a local *estimate* (exact
mode on but the poll fell back), the giant number itself degrades (≈ prefix, muted
tone, `estimate` tag). A local 90% must never masquerade as a server-true 90% — that
is the whole reason this app exists.

## Layout (440pt popover, top → bottom)
1. **Header** — `Throttle` + `PRO`/`FREE` pill + `EXACT` pill (inverted, green dot;
   only when a fresh exact snapshot exists). No top-right %, the hero owns it.
2. **Binding hero card** (`secondary.opacity(0.06)` fill, radius 10):
   - eyebrow: `Binding now · <window>` + `estimate` tag if degraded.
   - hero number: `46pt rounded bold monospacedDigit`, `%` at 19pt, optional `≈` at 30pt.
   - to its right: `used` / `N% headroom left`.
   - **UsageBar** (height 8, danger ticks at 80/95).
   - footer row: `resets <wall-clock>` … `closest to cap`.
3. **Two secondary rows** (the non-binding windows, canonical order):
   - `Title subtitle` … `[estimate] NN%` (mono).
   - **UsageBar** (height 5, no danger ticks) + `resets <wall-clock>` (caption2).
   - not-calibrated → `Set cap›` button (→ Calibration) + helper line.
4. **Savings footnote** — unchanged (one quiet line, lowest).
5. Pro section · actions · (warning strip when exact fails).

## Tokens
- Accent: system `accentColor`. Pressure only: `<80% accent · <95% orange · ≥95% red`
  (`progressTint`). Nothing else earns hue.
- Radii: 10 (hero card), Capsule (bars, pills, tags).
- Type: SF rounded for hero digits, `.subheadline`/`.caption`/`.caption2` elsewhere,
  `.monospacedDigit()` on every number.
- Degraded fill: `tint.opacity(0.45)` + diagonal Path hatch (`Stripes`). **No Canvas /
  no `.numericText` transition / no `.shadow`** — macOS 26.5 Metal regressions.

## States (all designed)
- **Exact** (fresh poll): crisp, EXACT pill, solid bars.
- **Estimate** (exact on, fallback): ≈ + `estimate` tags + hatched/muted bars, no EXACT pill.
- **Warning strip**: existing `exactModeWarningBanner` ("showing local estimates").
- **Not calibrated**: `Set cap›` per window; if none calibrated, three such rows, no hero.
- **Empty**: `No sessions yet — start one in Claude Code.` / Claude Code not detected.
- **Free vs Pro**: FREE pill; exact rows are Pro-gated upstream.

## Accessibility
- Bars are decorative; the % text is the source of truth (VoiceOver reads the row label
  + percent + estimate state). Hit targets for `Set cap›`/actions ≥ comfortable.
- Color is never the *only* signal — ≈/`estimate` text carries confidence; ticks +
  number carry pressure.

## Components added
- `UsageBar(pct:tint:degraded:height:showDangerZones:)` — track + leading-anchored
  Capsule fill, Path hatch when degraded, 80/95 ticks when `showDangerZones`.
- `Stripes: Shape` — diagonal hatch for the degraded fill.

Follow-up passes (separate): Stats, Settings, Project window, first-run — inherit this
vocabulary. Note: settings + first-run currently exist in *two* parallel forms
(inline-in-dropdown + standalone window) — unify during their pass.
