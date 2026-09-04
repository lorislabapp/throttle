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
- [x] Confirmed Developer ID Application identity `8333AB7C…` and the `Throttle DevID iCloud` / `Throttle Widget DevID` profiles live before archive.

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
- [x] Archived and exported the universal signed Developer ID app after recovering from a disk-full infrastructure failure.

## Assets

- [ ] Preserve the previous public DMG/appcast/page as rollback inputs.
- [x] Prepared a 3.5.1 DMG containing the exact exported app and `/Applications` symlink.

## Metadata

- [x] Prepared the non-published Sparkle entry for 3.5.1 (217), minimum macOS 14.0, from the final stapled DMG.
- [ ] Prepare the product-page version/link update without publishing it.

## Assemble

- [x] Signed the app, nested code and DMG with secure timestamps.
- [x] Pre-notarization DMG: 31,537,943 bytes; SHA-256 `a89838c176023d319d2b3013892057cf4754ca94dd74d806d740394f7fce1114`.
- [x] Final stapled DMG: 31,540,263 bytes; SHA-256 `796da4eff8ebeb53f167198fc0fc4de3addc8ce1414bfa6a970680cfa6eb8693`.

## Validate

- [x] Strict nested signature verification passed for the exported app, widget, Sparkle components and Research Vault helper.
- [x] Release smoke test passed 6/6 and Research Vault signed-bundle verification passed.
- [x] Mounted DMG payload verification passed; version/build are 3.5.1 (217), executable architectures are x86_64 and arm64.
- [x] Apple staple validation and Gatekeeper assessment passed as `Notarized Developer ID`.
- [x] Sparkle EdDSA signature was generated from the final stapled DMG and verified successfully.
- [ ] Local runtime validation without replacing the installed app.

## Submit

- [x] Apple notarization accepted; submission `9e455bb1-56ee-4585-8b30-b3718b745f9d`, status `Ready for distribution`, no reported issues. Ticket stapled successfully.
- [x] Public DMG upload authorized and completed for exactly `https://lorislab.fr/throttle/Throttle-3.5.1.dmg`.
- [ ] NOT AUTHORIZED: Sparkle appcast/page mutation. Publish DMG first, verify public bytes, then appcast, then page.

## Post-release

- [x] Public URL verified through normal and cache-busted requests: HTTP 200, content length 31,540,263 bytes; downloaded SHA-256 exactly `796da4eff8ebeb53f167198fc0fc4de3addc8ce1414bfa6a970680cfa6eb8693`.
- [x] Sparkle EdDSA signature verified successfully against a fresh download from the public URL.
- [ ] Verify the appcast top item and product-page link.
- [ ] Installation/relaunch remains a separate gate.

## Current verdict

Preparation is **PUBLIC DMG VERIFIED; APPCAST PUBLICATION NOT AUTHORIZED**. The source is integrated at `0bc2ebfa39b029c14109d019be5fcf6db8068e4c`; the notarized DMG is publicly retrievable byte-for-byte and its Sparkle signature verifies. The hosted macOS XCTest runner and the drifting DeepSearsh corpus remain open requalification items. No appcast/page publication, installation or push has occurred.
