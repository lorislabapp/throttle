# UI-SPEC — Cockpit top toolbar (Direction C · The Reveal Row)

Source: Claude Design project `683dc5a2…`, `Toolbar.html`, Direction C. Chosen 2026-07-03.

## Structure — two rows
**Row 1 (primary, 40pt, always visible)** — left→right:
- Identity: gauge glyph (15pt, opacity .88) + wordmark `Throttle` (12.5/620) + `Cockpit` (tertiary, 500). Wordmark hidden when narrow.
- zone separator (1×18, sep)
- View switcher (dominant): segmented, track bg, radius 8, pad 2. Each item icon(13)+label(11.5/560, secondary); ON = elevated bg + accent + 620. Icon-only when narrow.
- flexible spacer
- Stateful toggles (Audit, Shell): height 26, radius 7, inset ring `hair`, icon 13 + label(11/560). ON = accent 14% fill + accent 50% ring + accent ink. Icon-only when narrow.
- zone separator
- Reveal chevron: 26×26, chevron.down, tertiary; OPEN → rotate 180° + accent.
- Status: out-style mono text (9.5, tertiary, hidden narrow) · PRO pill (soft) · EXACT pill (solid).

**Row 2 (utility shelf, 0↔36pt, revealed by chevron)** — faint sub-shelf bg:
- Left: timeline nav (older/newer/live) when a session exists, else "No session open" (tertiary).
- spacer
- Utilities (26×26 tertiary glyphs): caffeine (accent when on) · theme menu · work activity · Claude setup · what's new · health.

The single hairline under the toolbar naturally sits under whichever row is last (row 1 when collapsed, row 2 when open) — no inter-row border, matching the mock's merge-on-open.

## Motion
- Reveal: row-2 height 0→36 + opacity, `.easeOut 0.18s`, clipped. Chevron rotation same curve. Respect reduceMotion (instant).

## Tokens (map to app semantics, keep cockpit palette)
- accent = `Color.accentColor`; sep/hair = `Color.primary.opacity(0.10)`; track = `.opacity(0.08)`; hover = `.opacity(0.06)`; tertiary = `.tertiary`.
- Radii: switcher 8 / item 6; toggle 7; util 6. NO gradient-filled SF Symbols (macOS 27 RenderBox). Solid fills only.

## Density / responsive
- `narrow` when bar width < 860: switcher + toggles collapse to icon-only, wordmark + out-style hidden. Width read via background GeometryReader → @State.
- Must stay legible at window minWidth 720.

## A11y
- Toggles `aria-pressed`/accessibilityValue On/Off. Chevron accessibilityLabel "More controls", expanded value. Hit targets: row-1 controls ≥26pt (tight but chrome), switcher items ≥26. Keep ⌘⇧T on shell toggle.
