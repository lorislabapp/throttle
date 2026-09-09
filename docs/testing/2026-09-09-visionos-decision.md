# visionOS: frozen, with a condition to revisit (2026-09-09)

## Decision

`ThrottleVision` stays as it is — a small windowed slice, built by CI, shipped
to nobody in particular. It is not developed further, and Throttle is not
repositioned around Vision Pro.

This is a decision to *keep* something cheap, not to abandon it. The target
compiles in every run, so it cannot rot silently, and the work needed to make
it useful stays small because the pieces it would need already exist.

## Why, from the research

Full reports: `docs/research/2026-09-09-visionos-agentic-coding-goat.md` and
`docs/research/2026-09-09-visionos-transport-and-market.md`.

- **The audience is shrinking, not growing.** IDC put 2024 at roughly 390,000
  units and Q4 2025 at roughly 45,000. Native apps peaked at Apple's own count
  of 2,500 in August 2024 and Appfigures counted 1,782 active in December 2025.
  The price went up, to $3,699. A cheaper headset is reported for late 2028.
- **We would not be first.** JarVS already ships multi-window VS Code on
  visionOS and markets running several AI coding agents in parallel; Panic
  shipped Prompt 3 with a bespoke immersive space in March 2026.
- **The ergonomics argue against the core use.** Apple's own safety guidance
  says take a break every 20–30 minutes. Biener et al. measured, over five
  eight-hour days with sixteen people, significantly worse eye strain, task
  load and productivity than at a desk, with one in eight dropping out on the
  first day.
- **The best indie outcome anyone has published** is about $4,000 a quarter
  across seventeen apps.

## What argues the other way, honestly

- Roughly half of Vision-only apps are paid, against about 4% store-wide: the
  audience is tiny but it buys.
- Mac Virtual Display has a real blind spot — same Apple Account, same Wi-Fi,
  about ten metres, one Mac, one display — that a native client does not.
- The transport needs no entitlement Apple must grant, so there is no gate to
  queue for later. Bonjour plus TCP costs one Local Network prompt; a Tailscale
  address costs nothing.
- The effort is small: the iOS terminal stack and the peer transport already
  exist, and SwiftTerm declares visionOS.

## The condition to revisit

Any one of these, on its own, is reason to look again:

1. Apple ships a Vision device under about $2,000, or a credible successor with
   a materially lighter head-mounted form.
2. A quarter's unit sales exceed the 2024 rate rather than continuing to fall.
3. Kevin actually works in the headset for a week and wants it — the personal
   pilot outranks every figure above.
4. A paying customer asks for it by name.

Until then the answer to "should we build the Vision Pro cockpit" is written
down, with its evidence, so it does not have to be re-litigated from instinct.

## What stays true regardless

The research that came out of this question was not wasted on the headset. Two
findings apply to the Mac product and have already been acted on:

- Prompt caches are model-scoped, so routing away mid-session strands a write
  proportional to the whole conversation. The router now says so.
- Supervising several agents is cheap; *returning* to them is expensive. The
  cockpit now reports what happened while attention was away, under alarm
  discipline borrowed from industrial practice.
