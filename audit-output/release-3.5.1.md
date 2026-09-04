# Throttle 3.5.1 (217) — Developer ID / Sparkle preparation journal

- Started UTC: 2026-09-04T05:59:00Z
- Intended channel: Developer ID direct distribution with Sparkle
- Intended bundle identifier: `com.lorislab.throttle`
- Intended minimum macOS: 14.0
- Intended update feed: `https://lorislab.fr/throttle/appcast.xml`
- Preparation authorization: local source reconciliation, versioning, build, archive, signing, packaging and validation
- Explicitly excluded: installation, Apple notarization upload, public upload, appcast/page mutation and publication

## Scope

- [x] Target selected: 3.5.1 (217).
- [x] Release worktree isolated at `/private/tmp/throttle-release-3.5.1-217` on `release/3.5.1-217`.
- [x] Initial source SHA: `42f26e91151fcfa8c1afcfd3346f956e270536ed9a`.
- [x] Publisher/team: LorisLabs / Apple Team `TDV6D5L785`.
- [x] Support contact: `support@lorislab.fr`.
- [x] Privacy source: `PRIVACY.md`; licence source: `LICENSE`.
- [x] Rollback rule: keep the currently installed/running app untouched and retain the previous public appcast until the new DMG is publicly retrievable and verified.
- [x] Authoritative source tree reconciled from `main`, the 13 committed feature changes, and the current 137-entry dirty snapshot.

## Preflight

- [x] `main` and `origin/main` both pointed to `42f26e91151fcfa8c1afcfd3346f956e270536ed9a` at preparation start.
- [x] CI for that SHA completed: SwiftLint passed; the macOS Release build failed on the old `main` tree.
- [x] Public appcast freshly read: top item remains 3.2.78 (178).
- [x] Public page freshly read: it still advertises 3.2.78.
- [x] Public `Throttle-3.5.0.dmg` freshly checked: HTTP 404.
- [x] Source reconciliation completed on isolated branch `release/3.5.1-217`.
- [x] Dirty checkout preserved unchanged; `.install-backups/` remains on disk and was excluded from Git because it contains signed app backups and provisioning material.
- [x] The 13 commits unique to `feat/cockpit-prompt-refiner`, the 41 commits unique to `main`, and the 137-entry current snapshot were reconciled.
- [x] Read-only merge simulation of the two committed branches found two overlapping Swift files: `MultiCockpitModel.swift` and `MultiCockpitRoot.swift`.
- [x] User explicitly authorized integrating all 137 current changes into 3.5.1; source snapshot commit: `ee1d9b7bb034d1d0f8398ad278a8d497836f4907`.
- [x] Snapshot secret scan passed with Gitleaks; 141 source files were captured, excluding `.install-backups/`.
- [x] Three merge conflicts resolved in `WindowCalculator.swift`, `ScopedCapModel.swift`, and `WindowCalculatorTests.swift`; retained weighted per-family pricing, fail-closed unknown composition, memoized probing, and comprehensive tests.
- [x] Final reconciliation committed locally; validation follow-up commit recorded after the checks below.
- [ ] Confirm Developer ID identity and required provisioning profiles live before archive.

## Build / archive

- [x] Set `MARKETING_VERSION` to 3.5.1 and `CURRENT_PROJECT_VERSION` to 217 after reconciliation.
- [x] Generated the Xcode project from the reconciled source.
- [x] Unsigned Release build succeeded with Xcode 27 beta after qualifying the colliding `ResearchVaultModel.ResearchFinding` type.
- [x] Research Vault dependency-boundary verification passed.
- [x] Reproduced the SwiftLint 0.65.1 baseline-generation regression with both Homebrew and the exact portable CI binary.
- [x] Restored the ratchet on SwiftLint 0.63.2, regenerated 3,064 known violations, and verified zero unsuppressed violations with that pinned binary.
- [x] CI privacy manifests, edge-agent self-test, shared Swift packages (42 tests), iOS security state (3 tests), ATS/LAN boundaries, fail-closed release scripts and source-drift checks passed.
- [x] Research Vault full product validation passed with 90 release tests across 21 suites; the differential reasoning oracle passed 10,000 programs against Lemmalog `7d6f1541130aba53949a2da90cc3e134cb0aac01`.
- [ ] Requalify the live DeepSearsh benchmark after its corpus is stabilized: expected corpus hash `e8ac68ed…`, current dirty corpus hash `1d75eb7b…`.
- [ ] Retry the hosted macOS XCTest suite with a stable runner: compilation succeeded, but Xcode 27 beta stalled before XCTest workers materialized and was interrupted after 168 seconds.
- [ ] Run the full release preflight and test suite.
- [ ] Archive and export the signed Developer ID app.

## Assets

- [ ] Preserve the previous public DMG/appcast/page as rollback inputs.
- [ ] Prepare a 3.5.1 DMG containing the exact exported app and `/Applications` symlink.

## Metadata

- [ ] Prepare a Sparkle entry for 3.5.1 (217), minimum macOS 14.0.
- [ ] Prepare the product-page version/link update without publishing it.

## Assemble

- [ ] Sign the app, nested code and DMG with secure timestamps.
- [ ] Record exact sizes and SHA-256 values.

## Validate

- [ ] Strict nested signature verification.
- [ ] Release smoke tests and Research Vault signed-bundle verification.
- [ ] Mounted DMG payload verification.
- [ ] Local runtime validation without replacing the installed app.

## Submit

- [ ] NOT AUTHORIZED: Apple notarization upload. Require a fresh exact GO naming the artifact, size and SHA-256.
- [ ] NOT AUTHORIZED: public DMG upload. Require a separate fresh exact GO naming the artifact and destination.
- [ ] NOT AUTHORIZED: Sparkle appcast/page mutation. Publish DMG first, verify public bytes, then appcast, then page.

## Post-release

- [ ] Verify public HTTP status, content length and downloaded SHA-256.
- [ ] Verify Sparkle EdDSA signature against the downloaded DMG.
- [ ] Verify the appcast top item and product-page link.
- [ ] Installation/relaunch remains a separate gate.

## Current verdict

Preparation is **IN PROGRESS**. The source is integrated and the unsigned Release build passes. Full clean-tree lint/tests and signed packaging remain before any notarization or publication gate.
