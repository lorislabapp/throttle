# Throttle — Stats panel · "The Statement" — handoff

Reproduction spec for the final Stats popover (verdict headline + plan statement).
Native macOS idiom: SF system text, SF Mono **tabular** digits, popover material,
flat sections divided by full-bleed hairlines, 16pt internal padding. Surface width **440pt**,
height driven by content (scrolls vertically).

## Run it
Open `index.html` (self-contained; loads React + Babel from CDN). The top **State**
selector switches scenarios; both Light and Dark are rendered side by side.

## Files
| File | Role |
|---|---|
| `index.html` | Runnable build (components inlined so it can't race on load). |
| `throttle.css` | Design tokens (Light + Dark) + popover chrome, pills, fill bar — inherited from the meter. |
| `stats.css` | Stats sections: range bar, plan ladder, trend, model split, period, heatmap, projects, the statement table (`.SB`) and the verdict headline (`.SF`). |
| `data.js` | `window.Throttle` — `tone(pct)` pressure helper (neutral / warn ≥80 / crit ≥95). |
| `stats-data.js` | `window.ThrottleStats` — the four scenarios + series/heatmap/ladder data. |
| `shared.jsx` | Primitives: `TitleRow`, `Pill`, `FillBar`, `WarningStrip`, `Actions`, `EstTag`, `Icon`. |
| `stats-components.jsx` | Sub-components: `Fig`, `RangeBar`, `SecHeader`, `PlanLadder`, `TrendChart`, `ModelSplit`, `PeriodStrip`, `Heatmap`, `TopProjects`, `ProLock`, `AdvisorEmpty`, `Reasoning`, + layout helpers (`ProExtras`, `StatsTail`, `StatsHead`). |
| `stats-final.jsx` | `StatsFinal` — the panel composition. |
| `stats-final-app.jsx` | State selector + Light/Dark stage + mount. |

## Layout (top → bottom)
1. **Title row** — `Throttle` wordmark · `PRO`/`FREE` pill · `EXACT` pill (Pro + server-true only).
2. **Range bar** — segmented `24h / 7d / 30d / all` (hit target ≥28pt) · "updated 2m ago".
3. **Verdict headline** (the hero) — kicker "PLAN ADVISOR · RECOMMENDATION", then one bold line:
   plan name (21pt/620) · price (20pt mono) · "— **best for your usage** · saves ≈€310/mo vs API".
4. **Plan statement table** — columns **PLAN / €·MO / FIT TO YOUR BURN**. Rows: Free / Pro `now` /
   Max 5× `best` / Max 20× / API equivalent `upper bound`. The **best** row is ruled (2pt left
   bar in `--ink`) and sits on `--bg-elev`.
5. **Reasoning** — one quiet line ("You burn 210M weighted tokens/wk, Opus-heavy (68%).").
6. **Usage trend** — three thin series (Session 5h solid / Weekly all dashed / Weekly Sonnet dotted).
7. **Model split** — Opus / Sonnet / Haiku as one weighted proportion bar + €/mo per tier.
8. **Period strip** — Today · This week · ≈ Saved (compact, mono).
9. **Pro extras** — 24×7 activity heatmap + top projects (locked behind one upsell on Free).
10. **Actions** — Open claude.ai/usage · Stats · Settings · Quit (+ Sign in when signed out).

## Color discipline (important)
Bars and chart series are **neutral graphite**. Colour is *earned*, never default:
- `--warn` only when a usage value crosses ~80%, `--crit` only past ~95% — **genuine at-limit pressure only.**
- The FIT column consequence words (*throttled, throttles Thu, comfortable, over-provisioned*) are
  **muted grey** (`--ink-2`), NOT red. Throttle never dramatises a projection it isn't certain of.
- `--accent` (blue) is for **links only** — never a bar or a chart line.

### Tokens — Light
```
--bg #F1F1F3   --bg-elev #FFFFFF
--ink #1D1D1F  --ink-2 rgba(60,60,67,.62)  --ink-3 rgba(60,60,67,.36)
--sep rgba(0,0,0,.085)  --hair rgba(0,0,0,.11)
--bar-track rgba(0,0,0,.085)  --bar-neutral #7B7C82
--warn #DE7A00  --crit #DD352B  --accent #0A6CF0
pill-solid bg #1D1D1F / ink #FFFFFF   pill-soft bg rgba(0,0,0,.065)
tick rgba(0,0,0,.22)  hover rgba(0,0,0,.052)
```
### Tokens — Dark
```
--bg #232325   --bg-elev #2D2D30
--ink #F5F5F7  --ink-2 rgba(235,235,245,.60)  --ink-3 rgba(235,235,245,.34)
--sep rgba(255,255,255,.085)  --hair rgba(255,255,255,.12)
--bar-track rgba(255,255,255,.10)  --bar-neutral #8E8E94
--warn #FF9F0A  --crit #FF453A  --accent #62A0FF
pill-solid bg #F5F5F7 / ink #1D1D1F   pill-soft bg rgba(255,255,255,.10)
tick rgba(255,255,255,.26)  hover rgba(255,255,255,.062)
```

## Type
- Text: SF system (`-apple-system`). Mono: SF Mono, `font-variant-numeric: tabular-nums` on **every** figure.
- Verdict plan 21/620 · price 20 mono · table plan 12.5/540 · €/mo 13 mono · FIT 11 ·
  section labels 10 uppercase 0.09em · period values 16 mono.

## Pills
- `PRO` — soft fill (`pill-soft`). `FREE` — outlined (1px `--hair`, transparent).
- `EXACT` — inverted solid (`pill-solid`) with a leading dot; shown only on Pro + server-true.

## Confidence rule (the signature)
Any value derived from local **estimates** rather than server-true data renders with an `≈`
prefix, muted tone (`--ink-2`), and — on bars — a diagonal hatch fill. Trend/split also show a small
`estimate` tag. The verdict headline itself degrades the same way (see Estimate / Free states).

## States (`stats-data.js`)
- **full** — Pro, server-true. EXACT pill, advice available.
- **estimate** — Pro, exact unavailable. Warning strip + `≈` + muted/striped figures + degraded headline.
- **notenough** — `<6h` of data. No table; "Need more usage to advise" with a collection meter.
- **free** — FREE pill, recommendation lowered to **Pro**, Pro extras behind one quiet upsell, sign-in shown.

## Model split & heatmap (graphite ramps, no hue)
- Split segments: `color-mix(in srgb, var(--ink) 72% / 42% / 20%, transparent)` for Opus / Sonnet / Haiku.
- Heatmap cell: `color-mix(in srgb, var(--ink) {intensity·70}%, transparent)` over `--bar-track`.

For SwiftUI: model the four scenarios as an enum, every figure as a monospaced-digit `Text`,
and gate `--warn`/`--crit` purely on the `tone(pct)` thresholds above.
