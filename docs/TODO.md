# Throttle — current work ledger

Last reconciled: 2026-08-28 against HEAD `6ed630f` plus the current dirty-worktree remediation.

This is the only active task list. Dated audit checklists, roadmaps and
`BACKLOG.md` are historical evidence. They do not become work merely because an
old checkbox is empty.

## Required before calling the reported bugs closed

| Status | Gate | Acceptance evidence |
|---|---|---|
| PASS — installed runtime | Replace installed Throttle 3.2.105 (204) with signed 3.2.107 (206) | installed Info.plist and strict nested signature match; exact exported executable digest; old app retained as a recoverable backup |
| PASS — installed runtime | Exercise repeated scalar/container MCP calls | 5 scalar + 5 container calls exit successfully; app remains active and no new Throttle crash report exists |
| PASS — physical runtime | Exercise local shell, local full-screen TUI and remote full-screen TUI scrolling | local shell and active local Claude TUI pass; one disposable remote Claude TUI visibly moved `118–200 → 74–161 → 118–200`, was stopped, and the remote API returned `sessions: 0` |
| PASS — local candidate | Validate the alternate-screen and Prompt Refiner regressions and assign a successor to public 3.2.106 (205) | 3.2.107 (206); 330 macOS tests, strict lint and universal unsigned Release bundle pass |
| PASS — installed runtime | Sign, install and launch the exact 3.2.107 (206) candidate | Developer ID identity, nested signature and installed Info.plist match; exact `/Applications` process remains active; Refiner local UI and self-test 7/7 pass |
| PASS — superseded evidence | Build/notarize 3.2.108 (207) | Apple accepted with 0 issues, but live 3.3.0 already uses build 207; publication was correctly aborted before mutation |
| PASS — local release candidate | Build and validate monotonic successor 3.3.1 (208) | Developer ID app/DMG, universal nested binaries, signed Research Vault gate, smoke 6/6 and mounted payload pass; DMG SHA-256 `e1e93631…a48ba` |
| PASS — notarized | Notarize 3.3.1 (208) | Apple submission `9209d96a-baed-4b66-91cf-f540f480597d` accepted with 0 issues; staple and app/DMG Gatekeeper pass; final SHA-256 `cfc62de2…c87` |
| PASS — published 2026-08-28 | Publish stapled 3.3.1 (208), then update Sparkle/page | public bytes match SHA-256 `cfc62de2…c87` and size `29284391`; Sparkle EdDSA, appcast top item, page, staple and Gatekeeper pass |
| PASS — installed/runtime | Replace WebKitUI MCP Native 0.5.11 with the signed 0.5.12 ARM64 companion package | recoverable 0.5.11 backup; installed 0.5.12 (512), exact hashes, normalized LaunchAgent/socket, strict signature/staple/Gatekeeper, 141/141 Debug + 141/141 Release and positive/negative two-client matrices PASS |
| PASS — published 2026-08-26 | Throttle 3.2.106 (205) archive, notarization, staple, publication and Sparkle update | Apple accepted; downloaded SHA-256 `1125c831…90f1b`; Gatekeeper accepted; appcast and edge verified |
| SUPERSEDED — public 2026-08-26 | Previous WebKitUI MCP Native 0.5.12 companion package | historical Apple/public proof remains, but downloaded SHA-256 `d5151ad2…bb326` failed current strict signature verification and was replaced on 2026-08-28 |
| PASS — published 2026-08-28 | Publish the repaired WebKitUI MCP Native 0.5.12 package | canonical and cache-busted downloads match SHA-256 `9dccd34a…9a62` and size `1760736`; manifest, app plus three binary signatures, secure timestamp, staple, version/build, page link and Gatekeeper pass |

## Local gates closed in this remediation

- MCP scalar JSON fragments are measured without an Objective-C exception.
- Precise trackpad scrolling forwards bounded SGR wheel reports when a TUI enables
  mouse tracking and SwiftTerm-compatible cursor keys in alternate-screen mode
  otherwise, for both local and remote terminals. The app and test bundle compile,
  and the unsigned universal Release build passes;
  XCTest execution is still pending because the active app-host runner did not
  materialize a worker and was cancelled without closing the user's live app.
- Scoped-cap diagnostics name the model supplied by Anthropic or remain `scoped`.
- The pinned SwiftLint baseline is refreshed only for the reduced terminal counts.
- macOS, shared/peer, iOS security and Edge tests are rerun from the current snapshot.
- WebKitUI MCP Native 0.5.12 repaired candidate is built, notarized, installed and published with full local/runtime/public-download verification. The older public companion is superseded.
- Cockpit Prompt Refiner M1 exposes output, rationale and local-only settings;
  local-only now fails closed against both network providers, and provider output
  is rejected before copy, mission storage or terminal insertion if it contains
  prohibited control bytes.
- Scoped-cap calculator tests inject their model token instead of reading or
  mutating the user's live preference domain.
- The 3.2.107 (206) local candidate passes 40/40 targeted Refiner/window tests,
  330 macOS tests with 2 skipped and no failures, strict SwiftLint 0.65.1,
  privacy/security gates and an unsigned universal arm64+x86_64 Release build.
- The Developer ID export is installed at `/Applications/Throttle.app`; its exact
  binary launches, installed hooks pass 10/10, the Refiner visibly uses Apple
  Intelligence locally, and the installed self-test passes 7/7 with zero frontier
  tokens. Gatekeeper still rejects it as unnotarized until the separate notarization gate.
- The unique 3.2.108 (207) successor closes the Research Vault release-boundary,
  disclosure and EN/FR catalog gaps. Its isolated Developer ID archive/export and
  signed DMG pass strict nested signature, universal-architecture, privacy,
  provisioning, smoke and mounted-payload checks. Apple notarization, staple and
  Gatekeeper are now PASS; it is not installed or published, and
  `/Applications/Throttle.app` remains the prior byte-identical build.

## Deferred product decisions — not active defects

- Broader multi-provider metering versus a focused Claude/Codex cockpit.
- Review-and-merge/IDE scope.
- Optional OAuth usage extras and extra-spend surfaces.
- New-session-only model right-sizing nudges.
- Web-render screenshots, accessibility-tree capture and per-render cost joins.
- Claude-driven terminal control.
- True ANN/vector backend and bundled model choices at larger corpus scale.
- TOON/CCR or lossy tool-result rewriting without task-success evidence.
- Automatic semantic read rewiring without explicit user consent.

## Explicit NO-GO until new evidence or user decision

- Keep-alive cache pings that spend quota.
- Silent lossy transcript or tool-result removal.
- Semantic response caching with wrong-hit/poisoning risk.
- Automatic mid-session model switching that destroys provider prompt caches.
- External marketing posts, publication, deployment, commit or push without an
  explicit operation-specific authorization.
