# UI-SPEC — Throttle Stats panel (Direction B-hybrid · "The Statement")

Chosen via Claude Design (2026-06-05). Inherits the meter's cockpit tokens
(`UI-SPEC-meter.md`): flat sections, full-bleed hairlines, 16pt padding, graphite
bars, mono digits, accent = links only, confidence ≈/estimate.

## Principle
The Plan Advisor verdict is the hero. A one-line **verdict headline** answers
"is my plan right?" instantly; a **plan statement table** (price + fit-to-burn per
plan) justifies it. Throttle's anti-overconfidence ethos: the FIT column shows
muted consequence words (throttled / tight / comfortable / over-provisioned) — **no
red, no specific "throttles Thursday" forecast** (the caps are empirical).

## Layout (440pt, scrolls)
1. Title row: back chevron · "Stats" · PRO/FREE + EXACT pills.
2. Range bar: 24h/7d/30d/all segmented · "updated".
3. **Verdict hero**: kicker `PLAN ADVISOR · RECOMMENDATION`, then
   `<best plan> €<price>/mo`, then `— best for your usage · saves €X/mo vs API`.
4. **Statement** (`PLAN STATEMENT · VS API`): columns Plan / €·mo / fit-to-burn.
   Every plan (Free/Pro now/Max5× best/Max20×) + API-equivalent (upper bound). Best
   row highlighted (`bg-elev` + 2px leading ink bar). FIT muted, best→ink.
5. Reasoning: `You burn <N> weighted tokens/wk, Opus-heavy (X%).`
6. Usage trend (3 graphite series — session solid / weekly dashed / sonnet dotted).
7. Model split (weighted bar Opus/Sonnet/Haiku graphite + per-tier €/mo API).
8. Period strip: today · this week · ≈€ saved.
9. Pro: activity heatmap + top projects · Free: one ProLock.
10. Tail: Open claude.ai/usage · Share badge · Back.

## States
- **Full** (Pro, advice available) · **Estimate** (exact on but stale → ≈ + tags) ·
  **Not enough data** (`Need more usage to advise`, no table) · **Free** (ProLock,
  recommendation realistically lower).
- `est = exactModeEnabled && exact snapshot not fresh` — same rule as the meter.
  Pure-local users are NOT flagged (local token data is real truth).

## Backend extension
`PlanAdvisor` gains `Fit` (throttled/tight/comfortable/over-provisioned), a
`fit(weeklyTokens:planCapacity:)`, and `ladder(...)` → per-plan rows. No throttle-day
forecast — honest by design.

## Tokens / a11y — inherit the meter. Charts are Path-based (no Canvas), heatmap is
RoundedRectangles (no Metal). Colour reserved for genuine at-limit pressure only.
