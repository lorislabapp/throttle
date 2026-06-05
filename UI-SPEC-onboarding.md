# UI-SPEC — Throttle first-run onboarding (Direction C · "The Living Meter")

Chosen via Claude Design (2026-06-05). Inherits the meter/Stats/Settings cockpit
tokens. Lives inline in the 440pt dropdown (`FirstRunInline` in `DropdownView.swift`,
shown when `!firstRunDone`), edge-to-edge. **Dead standalone `FirstRunWindow.swift` +
`FirstRunStep.swift` deleted — one code path.**

## Principle
Onboarding IS the product. The real meter sits at the top, empty and ghosted, and
**fills in live as the user answers**. Each answer collapses to a confirmed row. The
payoff is shown, not promised, before the user commits.

## Layout (440pt, edge-to-edge)
1. **Brand hero**: gauge mark · "Throttle" · "Accurate Claude Code usage, in your menu bar."
2. **Living meter card** (`controlBackgroundColor` fill, radius 13, hairline border):
   "YOUR METER" label · Throttle + PRO/AUTO pill (once filled) · three rows (Session 5h /
   Weekly all / Weekly Sonnet). Until a plan is picked: names+caps ghosted (opacity 0.5),
   bars empty, caps read "— —". On pick: caps + graphite bars animate in (demo 47/12/3%);
   "Skip" → muted full bars + "auto".
3. **Progress dots** (3 segments, accent as `qi` advances).
4. **Conversational thread**:
   - qi 0 → q-card "Which Claude plan are you on?" + privacy reassurance + **plan picker**
     (Pro €19 4M·60M / Max 5× €90 8M·200M / Max 20× €180 20M·800M / Skip — auto-calibrate).
     Picking → confirmed row + qi 1.
   - qi 1 → q-card "Keep Throttle in your menu bar?" + launch toggle + "Looks good" → qi 2.
   - qi 2 → confirmed launch row + Exact-mode teaser (breadcrumb) + "Open my meter" → apply().
   - Confirmed rows are tappable ("Edit") to step back.

## Tokens
- Accent (system blue) only on: chosen plan, radio, toggle, progress dots, primary
  buttons, "Edit"/confirmed checks. Everything else neutral graphite. No pressure colour.
- Mono tabular digits for caps. Radii 9–13. Hairlines + 16pt padding.
- One motion moment: the meter bars + caps easing in on plan pick (0.55s). No Canvas /
  numericText / shadow (macOS 26.5).

## Wiring (preserved)
`apply()` writes the real per-plan calibration presets (pro 4M/60M, max5× 8M/200M,
max20× 20M/800M; skip → none) via `CalibrationEngine.setManual`, marks first-run done,
enables login items, and starts Exact polling if already signed in.

## States: not-picked (ghosted meter) · picked (filled) · skip (auto/muted) · final
(launch confirmed + teaser). Both themes inherit the popover material.
