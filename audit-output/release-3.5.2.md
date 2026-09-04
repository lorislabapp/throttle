# Throttle 3.5.2 (218) — Developer ID / Sparkle preparation journal

- Started UTC: 2026-09-04T10:48:53Z
- Intended channel: Developer ID direct distribution with Sparkle
- Intended bundle identifier: `com.lorislab.throttle`
- Intended minimum macOS: 14.0
- Intended update feed: `https://lorislab.fr/throttle/appcast.xml`
- Preparation authorization: local versioning, project generation, unsigned build and tests
- Explicitly excluded: Developer ID signing, installation, Apple notarization upload, public upload, appcast/page mutation and publication

## Scope

- [x] Target selected: 3.5.2 (218).
- [x] Release branch created locally as `release/3.5.2-218` from source commit `4314d79481d42b64587a61663f55c1a68eee7f10`.
- [x] Release purpose: include Plan orientation, the dedicated AI Routing window, embedded-Qwen/Ollama truth, and local/frontier recovery policy that were committed after the public 3.5.1 artifact.
- [x] Publisher/team retained: LorisLabs / Apple Team `TDV6D5L785`.
- [x] Rollback rule: keep installed 3.5.1 and the public 3.5.1 appcast untouched until a separately authorized 3.5.2 publication is verified byte-for-byte.

## Preflight

- [x] Public 3.5.1 release journal reconciled; 3.5.1 (217) predates source commit `4314d79`.
- [ ] Confirm fresh public appcast state before signed packaging.
- [ ] Confirm Developer ID identity and provisioning profiles before signing.
- [ ] Complete visual and accessibility validation of Plan and AI Routing.

## Build / archive

- [x] Set `MARKETING_VERSION` to 3.5.2 and `CURRENT_PROJECT_VERSION` to 218.
- [x] Generated the Xcode project from `project.yml`.
- [x] Full local suite passed: 561 XCTest tests with 5 skipped and 0 failures, plus 3 Swift Testing tests with 0 failures; result bundle: `/private/tmp/throttle-ai-routing-derived/Logs/Test/Test-Throttle-2026.09.04_12-57-21-+0200.xcresult`.
- [x] Unsigned Release build succeeded with `CODE_SIGNING_ALLOWED=NO`; output: `/private/tmp/throttle-ai-routing-derived/Build/Products/Release/Throttle.app`.
- [x] Release bundle reports 3.5.2 (218); the local build is arm64 and only linker-signed ad hoc, so it is not a distributable artifact.
- [x] First clean-cache test attempt failed from infrastructure disk exhaustion (`No space left on device`), not a source diagnostic; two task-created DerivedData caches were removed and the full retry passed.
- [ ] Archive/export the signed Developer ID app — requires a fresh signing GO.

## Assets

- [ ] Prepare `Throttle-3.5.2.dmg` from the exact signed export.

## Metadata

- [ ] Prepare, but do not publish, the Sparkle 3.5.2 (218) entry.
- [ ] Prepare, but do not publish, the product-page update.

## Assemble

- [ ] Sign the app, nested code and DMG — requires a fresh signing GO.
- [ ] Record exact pre-notarization size and SHA-256.

## Validate

- [ ] Verify strict nested signatures, DMG payload, architectures and version/build.
- [ ] Run signed-bundle smoke tests.
- [ ] Validate local runtime without replacing the installed app.

## Submit

- [ ] Apple notarization upload — requires a fresh exact GO naming the artifact and SHA-256.
- [ ] Public DMG upload — requires a second fresh exact GO naming the destination.
- [ ] Sparkle appcast publication — requires a separate exact GO.
- [ ] Product-page publication — requires a separate exact GO.

## Post-release

- [ ] Verify public HTTP status, byte length and downloaded SHA-256.
- [ ] Verify Sparkle signature and top appcast item from a fresh public response.
- [ ] Installation/relaunch remains a separate gate.

## Current verdict

Preparation is **LOCALLY VALIDATED WITH OPEN UI/SIGNING GATES**. Versioning, the full test suite and the unsigned Release build passed. Visual/accessibility qualification and all Developer ID operations remain open. No distributable signing, installation, notarization, upload or publication has occurred.
