# Design — Circuit breaker / cost rules (notebook Q3 #3)

**Idea:** an automated rules engine that actively PAUSES a runaway session (or
blocks an expensive model) before Anthropic's hard 5h cap locks the user out.

## What's now built (the safe half)
- **Predictive cap nudge** (this session): `ThresholdNotifier.forecastCapETA`
  derives burn rate from the pct delta and warns "cap in ~N min" before the
  fixed 80/95 thresholds. This is the *warn* half — safe, shipped.

## The risky half: actively ACTING (pause / block)
"Pause the session" means interrupting the user's live `claude` mid-work, or
intercepting a request. That's a behavioral intervention — high blast radius.

### Risks
1. **Interrupting real work.** A false "runaway" reading (a legit big task) that
   auto-pauses costs the user more than a cap-hit would.
2. **No clean pause primitive.** Claude Code has no "pause" API. Options are
   crude: SIGSTOP the process (freezes mid-tool, risks corrupt state) or refuse
   input — both ugly.
3. **Trust.** An app that can halt your agent on its own judgment is a big ask;
   one wrong stop and the user disables it forever.

### If built — guardrails
- OFF by default; opt-in with an explicit "Throttle may pause my session" consent.
- Default to a HARD WARNING + one-click "pause" the USER triggers, not auto-kill.
- True auto-pause only as an extreme, separately-enabled mode with a high
  threshold (e.g. ≥97% AND burn ETA < 5 min), a countdown the user can cancel,
  and SIGCONT-able pause (reuse the hibernation plumbing) — never a hard kill.
- Per-model rules ("never let Opus run past X%") as a softer, safer variant:
  surface a switch-to-cheaper-model nudge rather than blocking.

## Verdict
**Ship the WARN (done). Defer the ACT.** The predictive nudge already delivers
most of the value at zero risk. Auto-pause is a trust/▲blast-radius gamble; only
build it opt-in, warn-first, cancelable, reusing hibernation's SIGSTOP/CONT — and
only if users actually ask to be auto-protected. Medium priority, gated on demand.
