# Throttle — remote terminal (iPhone drives a Mac Claude Code session)

Pivot away from the read-only mirror: let the phone (and visionOS) **drive** a live
session running on the Mac. Design distilled from a 2026-07 deep-research pass
(mosh USENIX'12, Eternal Terminal, Blink Shell) + the no-VPN constraint.

## Non-negotiable constraints
- **No VPN entitlement** (no enterprise account). We build **no** VPN / NAT-traversal /
  relay. Transport is either the LAN or the **user's own Tailscale** (a separate app
  that owns the tunnel — our app just opens a normal `NWConnection` to the tailnet
  IP/MagicDNS, needing no entitlement). "integrate-don't-compete with Tailscale."
- **Doctrine pivot**: this is deliberate control, not measure-only. Keep it gated
  (opt-in, PRO, per-session attach) and bootstrapped on the existing authenticated
  channel — never a socket-open remote-exec backdoor.

## Transport (keep what's shipped)
- Reuse the **TCP + TLS-PSK** peer link (`ThrottlePeer`, already proven). Do **not**
  rewrite to QUIC now: the research confirms even native `NWProtocolQUIC` (macOS 26)
  does **not** transparently survive Wi-Fi↔cellular — you still need an app-layer
  resync layer, so QUIC's gain here is marginal.
- **Connection discovery order** in `PeerConnector`: (1) Bonjour `_throttle._tcp` on
  the LAN, (2) a configured **Tailscale hostname** fallback for off-LAN. Same TLS-PSK
  either way.

## Stream model — octet stream + predictive echo (NOT mosh screen-diff)
Both ends already run **SwiftTerm**, so ship the raw PTY octet stream, not mosh's
server-side screen-state diff (which needs a full emulator server-side to compute
diffs). Frames (already in `PeerMessage`): `termAttach` / `termOut` / `termIn` /
`termResize` / `termDetach`.

## The GOAT differentiator — mosh predictive local echo (port to iOS SwiftTerm)
Parse keystrokes **locally** into an overlay layer rendered **before** server
confirmation. Measured in mosh: ~70% of keystrokes shown instantly, 0.9%
misprediction, each wrong cell corrected within ≤1 RTT.
- **Gate by SRTT hysteresis**: engage prediction only when the smoothed RTT exceeds a
  high trigger; disengage below a low trigger. On a fast LAN, no speculation.
- **Underline** unconfirmed predictions so a later correction never misleads.
- **Misprediction detection = framebuffer comparison** (mosh `get_validity()` →
  Correct / Pending / IncorrectOrExpired), **not** an epoch-ack timeout (that variant
  was refuted in the research). On mismatch: reset the cell / kill the prediction epoch.
- Implement as a SwiftTerm overlay on the phone; the Mac side is untouched by this.

## Resilience — Eternal-Terminal-style resumable stream
- Per-session monotonic **sequence numbers** on `termOut`; the Mac keeps a bounded
  **CatchupBuffer** ring of recent output keyed by a persistent **client-id**.
- On reconnect (LAN drop, Wi-Fi↔cellular, Bonjour→Tailscale), the phone sends its last
  acked seq; the Mac **backfills** the gap from the ring, then resumes live — the PTY
  and the session stay alive on the Mac throughout.
- Roaming inspiration (mosh): trust the highest-seq authentic frame's source; the
  resumable layer makes the transport swap invisible to the session.

## Security
- Bootstrap on the **existing TLS-PSK pairing** (CloudKit-anchored secret) — the
  authenticated channel already exists; the terminal rides inside it.
- **Per-session attach**: the phone must `termAttach` a specific session id; default
  to a Mac-side confirmation/allow-list for first attach. Identity bound to the
  session credential, not the socket. No unauthenticated control path.

## Increment plan
1. **[done]** Protocol frames (`termAttach/Out/In/Resize/Detach`) + resize codec. 12 tests.
2. **Mac PTY bridge** — surgical tap on `DroppableTerminalView` (output hook →
   `termOut`; inject `termIn` via `send(txt:)`; `termResize`) + a `PeerTerminalBridge`
   routing peer control frames ↔ `MultiCockpitModel`. Touches the scarred cockpit file
   → diff-review before commit.
3. **iOS SwiftTerm** — add the SwiftTerm dep to `ThrottleiOS`; a `RemoteTerminalView`
   (feed `termOut` bytes, capture the iOS keyboard incl. esc/ctrl/tab/arrows → `termIn`,
   send `termResize`).
4. **Predictive echo** overlay + SRTT gating (the differentiator).
5. **Resumable layer** — seq + CatchupBuffer + client-id backfill; Tailscale fallback host.
