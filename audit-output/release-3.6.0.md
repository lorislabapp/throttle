# Throttle 3.6.0 (220) — release preparation

Status: PREPARING, not published. Candidate = `integration/3.6.0-sota-release`
(PR draft #4), the unified A+B+C tree plus the 9 September lots. The 219
candidate of `release/3.6.0-219` (3abf6a6) is superseded: it carries none of
the Cockpit stop/hibernation fixes, the CSV export fix, the durable task log,
the outbound policy, the corpus freeze or the MCP authority.

- [x] Scope: macOS Developer ID + Sparkle, existing channel and publisher unchanged.
- [x] Live feed read: 3.5.2 (218) remains the newest item on 2026-09-09.
- [x] Unified tree CI: run 34312608324 fully green on bdac13b (macOS 646 cases,
      iOS, Vault Debug/Release, visionOS, quality, validator-evidence).
- [x] Pre-release audits on the candidate: privacy manifests complete (4
      targets), App Review compliance 6/6, security scan = known false
      positives only (milestone counter in UserDefaults, test fixtures,
      literal-regex `try!`).
- [x] Version/build set to 3.6.0/220; Sparkle notes extended (FR).
- [ ] Fresh CI green on the exact release revision (last lots: 4f4b49e+).
- [ ] Fast-forward `main` to the candidate; cut `release/3.6.0-220`.
- [ ] Archive/export universal signed candidate — LOCAL, needs a memory window
      (this Mac killed two background waits for memory on 2026-09-09).
- [ ] Pre-notarization bundle/signature checks and mounted DMG verification.
- [ ] Runtime/UX/AX/companion qualification (Kevin): hibernation/Quit on a
      loaded Mac, CSV export from About, diagnostics preview, iOS mirror.
- [ ] Fresh approval for exact notarization upload.
- [ ] Notarization, staple and Gatekeeper verification.
- [ ] Assemble canonical staging from live site; verify exact bytes.
- [ ] Fresh approval for exact public upload (Kevin runs it with `!`).
- [ ] Public download, cache-bust, Sparkle isolated update and T+15 checks.
- [ ] Independent final GO and handover.

Use only scripts/stage-release.py, scripts/publish-release.mjs and
scripts/verify-public-release.sh for publication. Preserve the website's seven
working files. Nothing here authorizes installation or restart of the working
app, a production edge-agent upgrade, or any upload.

Rollback candidate: published 3.5.2 (218).
