# Throttle 3.5.2 (218) — Developer ID / Sparkle preparation journal

- Started UTC: 2026-09-04T10:48:53Z
- Intended channel: Developer ID direct distribution with Sparkle
- Intended bundle identifier: `com.lorislab.throttle`
- Intended minimum macOS: 14.0
- Intended update feed: `https://lorislab.fr/throttle/appcast.xml`
- Preparation authorization: local versioning, project generation, unsigned build and tests
- 2026-09-07 authorization (user, in session): ship "everything" — merge the Research Vault lots 1-4 branch plus the session activity filter, sign, notarize, publish DMG + Sparkle appcast + product page. Explicitly excluded: installing or relaunching the app on the user's Mac.

## Scope

- [x] Target selected: 3.5.2 (218).
- [x] Release branch created locally as `release/3.5.2-218` from source commit `4314d79481d42b64587a61663f55c1a68eee7f10`.
- [x] Release purpose: include Plan orientation, the dedicated AI Routing window, embedded-Qwen/Ollama truth, and local/frontier recovery policy that were committed after the public 3.5.1 artifact.
- [x] 2026-09-07: widened on user decision to also include `feat/research-vault-lots-1-4` (Research Vault lots 1-4, 14 commits) and the new rail/tab-bar activity filter (`ce083de`). Merge commit `aaa8d86`; 11 conflicts resolved by provenance: vault files took the feature side (the release side held older snapshots of that same branch), WindowCalculator/ScopedCapModel/their tests/URL intake took the release side (3.5.1 calibration reconciliation). Follow-up `9e2b8b7` removed a duplicated `knowledgeMenu(compact:)` and updated a MemoryHealth test fixture.
- [x] Publisher/team retained: LorisLabs / Apple Team `TDV6D5L785`.
- [x] Rollback rule: keep installed 3.5.1 and the public 3.5.1 appcast untouched until a separately authorized 3.5.2 publication is verified byte-for-byte.

## Preflight

- [x] Public 3.5.1 release journal reconciled; 3.5.1 (217) predates source commit `4314d79`.
- [x] Fresh public appcast read 2026-09-07 before packaging: top item 3.5.1 (217); 93,637 bytes; SHA-256 `7625700c70f3ba61…`; preserved locally.
- [x] Developer ID identity `8333AB7C…` present; `Throttle DevID iCloud` and `Throttle Widget DevID` profiles valid to 2044.
- [ ] Visual and accessibility validation of Plan and AI Routing — not performed (no run/install on this Mac by user instruction).

## Build / archive

- [x] Set `MARKETING_VERSION` to 3.5.2 and `CURRENT_PROJECT_VERSION` to 218.
- [x] Generated the Xcode project from `project.yml`.
- [x] Full local suite passed: 561 XCTest tests with 5 skipped and 0 failures, plus 3 Swift Testing tests with 0 failures; result bundle: `/private/tmp/throttle-ai-routing-derived/Logs/Test/Test-Throttle-2026.09.04_12-57-21-+0200.xcresult`.
- [x] Unsigned Release build succeeded with `CODE_SIGNING_ALLOWED=NO`; output: `/private/tmp/throttle-ai-routing-derived/Build/Products/Release/Throttle.app`.
- [x] Release bundle reports 3.5.2 (218); the local build is arm64 and only linker-signed ad hoc, so it is not a distributable artifact.
- [x] First clean-cache test attempt failed from infrastructure disk exhaustion (`No space left on device`), not a source diagnostic; two task-created DerivedData caches were removed and the full retry passed.
- [x] Merged tree: full local suite passed 2026-09-07 — 578 XCTest tests, 5 skipped, 0 failures (`/private/tmp/throttle-352-derived/Logs/Test/Test-Throttle-2026.09.07_07-51-42-+0200.xcresult`, cache since removed for disk).
- [x] Archived and exported the universal signed Developer ID app via `scripts/build-dmg.sh --notarize` from `/private/tmp/throttle-release-3.5.2-218` (release build dir `build/`).

## Assets

- [x] `Throttle-3.5.2.dmg` built from the exact signed export; payload verified (3.5.2/218, arm64 + x86_64).

## Metadata

- [x] Sparkle 3.5.2 (218) entry generated from the final stapled DMG (EdDSA verified against the app's `SUPublicEDKey`); staged appcast = live appcast + new top item with release notes, 94,827 bytes, SHA-256 `d16a0544afd398d89b0e364ebc275abdfba46a7b1a0018d48d6540d1181a7dd8`, 75 items.
- [x] Product page staged from the fresh public page with Cloudflare/WebMCP transformations removed (clean 3.5.1 source reproduced byte-for-byte at 26,794 bytes); 3.5.2 page 26,794 bytes, SHA-256 `42de2f725982d6ef26372ffd9201a042dad4496a925e8e27e44926c97b7ae490` (link → `Throttle-3.5.2.dmg`, `v3.5.2 · 31.8 MB`).

## Assemble

- [x] Signed the app, nested code and DMG with secure timestamps.
- [x] Final stapled DMG: 31,832,615 bytes; SHA-256 `c7ff74053564b0afeecb6379813401874e7916150d3b12afa6e4e4cbb56993c1`.

## Validate

- [x] Strict nested signatures, DMG payload, architectures and version/build verified by the build script.
- [x] Signed-bundle smoke tests and Research Vault bundle verification passed.
- [x] `stapler validate` and `spctl` assessment passed as `Notarized Developer ID` for both the DMG and the exported app.
- [ ] Local runtime validation — not performed (user is working in the installed 3.5.1; no relaunch).

## Submit

- [x] Apple notarization accepted; submission `b208d0fe-f88a-47bf-918a-9e1c39515588`; ticket stapled.
- [x] Public upload run by the user 2026-09-07 (`publish-throttle.mjs`, one isolated archive `throttle-release-20260907062756.zip`, 5 entries, merge-extract); deploy trigger 200; stamp `20260907062756-937bg2wx` verified live.
- [x] Sparkle appcast published in the same upload.
- [x] Product page published in the same upload.

## Post-release

- [x] Public DMG: HTTP 200 with content length 31,832,615 through both a plain and a cache-busted request; downloaded SHA-256 exactly `c7ff74053564b0afeecb6379813401874e7916150d3b12afa6e4e4cbb56993c1` (identical bytes, so the EdDSA signature verified locally holds for the public file).
- [x] Public appcast: 94,827 bytes, SHA-256 `d16a0544…` (identical to the staged file); top item 3.5.2 / `<sparkle:version>218` from both a fresh and an edge-cached response.
- [x] Public page advertises `Throttle-3.5.2.dmg`, `v3.5.2 · 31.8 MB`.
- [ ] Installation/relaunch remains a separate gate (user is working in the installed 3.5.1).
- [x] `release/3.5.2-218`, `main` (fast-forwarded to the release tip) and `feat/research-vault-lots-1-4` pushed to origin.
- [x] CI ratchet root cause fixed: the 3.5.1 baseline held absolute `/tmp` paths; regenerated repo-relative with the pinned SwiftLint 0.63.2, guards added to `build-dmg.sh` and CI.
- [x] Release path made repeatable: `scripts/stage-release.py`, `scripts/publish-release.mjs`, `scripts/verify-public-release.sh`, runbook `docs/RELEASE.md`; the stage script reproduces the published 3.5.2 files byte-for-byte and the verifier passes against the live site.
- [x] `lorislab-website` reconciled with origin (34 local + 5 remote commits, uniform asset stamp) and its `throttle/` files synced to the published appcast and page.

## Post-publication hardening (2026-09-07, after the release)

- [x] CI green on `main` for the first time since 3.2.96 (run 34096405323, `860e58b`), confirming the baseline was the sole cause.
- [x] Release path made fail-closed on the two things that only surface after users download: staging now refuses a DMG with no stapled ticket and re-verifies the EdDSA signature against the bytes with Sparkle's `sign_update`. CI syntax-checks the publish scripts and pins two invariants (staging reads the live site; publishing proves itself with the deploy stamp).
- [x] Shipped 3.5.2 dSYMs preserved outside `/private/tmp`, which is cleared on reboot: `.install-backups/dSYMs-3.5.2-218/` (Throttle, widget, Research Vault agent; 107 MB, with UUIDs). Without this, a 3.5.2 crash report could never have been symbolicated.
- [x] Filter defects found in review and fixed for the next release (NOT in the shipped 3.5.2): the tab bar was given the rail's stacked empty state, the empty-state message was a ternary of literals that silently picked the non-localizing `Text` overload, and the seven new strings were missing from the catalog. Tier labels are now `Live sessions` / `Active sessions`, and `No sessions running` no longer translates to `Aucune session active`, which contradicted the new Active tier.
- [x] Release build intermediates (archive, export) removed after the durable artifacts were verified; the notarized DMG and signed appcast entry are kept.

## Current verdict

2026-09-07: **PUBLISHED AND VERIFIED**. 3.5.2 (218) is live on `https://lorislab.fr/throttle/` and at the top of the Sparkle feed; clients on 217 will be offered it. The installed app on the release machine was not touched.
