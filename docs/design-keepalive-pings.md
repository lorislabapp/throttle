# Design — Cache keep-alive pings (notebook finding #3)

**Idea:** fire an ultra-terse request every ~4.5 min during idle so Anthropic's
prompt cache (5-min TTL) never expires, avoiding the ~25% cache-rebuild penalty
when the dev comes back from a break.

## Feasibility
- Technically doable: a background timer in Throttle (or a managed hook) that
  issues a minimal `claude -p` / API call against the live session's cached
  prefix every < 5 min while the session is idle.

## Why this is the RISKIEST finding (recommend NOT shipping as-is)
1. **It spends to "save."** Every keep-alive ping is billed input/output tokens
   and counts against the 5h/weekly cap — the exact thing Throttle exists to
   protect. A ping every 4.5 min = ~13/hr = ~300/day of idle pinging. The
   cache-rebuild it avoids may be cheaper than the pings themselves. Net value
   is unproven and possibly negative.
2. **Fair-use / ToS exposure.** Automated background traffic to keep a cache warm
   with no user intent is the kind of pattern that can read as gaming usage
   limits. Shipping this to all users could put accounts (and Throttle) at risk.
3. **Cap pressure.** On a user who is near their weekly cap, idle pings could be
   what tips them over — a catastrophic inversion of the wedge.

## If it ships at all — hard guardrails
- OFF by default, explicit opt-in with a plain-English cost warning.
- Hard stop when the binding window is ≥ ~70% (never ping near the cap).
- Only while a session is genuinely idle AND the user is at the machine.
- Show realized ping cost vs estimated rebuild saved, live — so the user sees if
  it's actually net-positive, and auto-disable if it isn't.

## Verdict
**Do NOT build for general release.** The downside (spend + ToS + cap pressure)
outweighs a speculative, possibly-negative saving. If Kevin still wants it, ship
it as a guarded, opt-in, cap-aware experiment with live net-value display — and
pull it the moment the math or ToS posture looks bad. Lowest priority of all
notebook findings.
