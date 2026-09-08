# Throttle 3.6.0 (219) — release preparation

Status: PREPARING, not published. The active SOTA loop and its remaining runtime
gates are recorded in docs/audits/THROTTLE-SOTA-REMEDIATION-2026-09-07.md.

- [x] Scope: macOS Developer ID + Sparkle, existing channel and publisher unchanged.
- [x] Live feed read: 3.5.2 (218) remains the newest item on 2026-09-08.
- [x] Developer ID identity 8333AB7CD909731530AC62DD28CCA47C8D288225 available.
- [x] Local suite: 608 passed, 5 skipped; pinned SwiftLint 0.63.2 passes.
- [x] Independent lot15 review: no new P0/P1/P2 in that source delta.
- [x] Version/build bumped to 3.6.0/219; release notes drafted.
- [x] Archive/export universal signed candidate, prepare-only exit 0.
- [x] Pre-notarization bundle/signature checks and mounted DMG verification.
  DMG 32,284,439 bytes, SHA-256 e30c2ef0366d0de9c1ded3e50dcbf3bcb84382b49e8b589e5c83b99b4b727c5f.
  Candidate manifest and dSYMs retained in the ignored evidence directory.
- [ ] Runtime/UX/AX/companion qualification and independent INTERIM review.
- [ ] Fresh CI on the exact source revision.
- [ ] Fresh approval for exact notarization upload.
- [ ] Notarization, staple and Gatekeeper verification.
- [ ] Assemble canonical staging from live site; verify exact bytes.
- [ ] Fresh approval for exact public upload.
- [ ] Public download, cache-bust, Sparkle isolated update and T+15 checks.
- [ ] Independent G9 final GO and handover.

Use only scripts/stage-release.py, scripts/publish-release.mjs and
scripts/verify-public-release.sh for publication. Preserve the website's seven
working files. This preparation does not authorize installation or restart of the
working app, a production edge-agent upgrade, or any upload.

Rollback candidate: published 3.5.2 (218). Before any installation, preserve the
installed app and relevant user data according to the concrete qualification plan.
Do not assume a schema downgrade is safe.
