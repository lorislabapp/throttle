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
- [ ] Public upload (DMG + appcast + page in ONE isolated archive, merge-extract over `public_html/throttle/`): the automated session was blocked by the tool classifier; to be run by the user: `node <scratchpad>/publish-throttle.mjs <scratchpad>/stage-352`.
- [ ] Sparkle appcast publication — same isolated upload as above.
- [ ] Product-page publication — same isolated upload as above.

## Post-release

- [ ] Verify public HTTP status, byte length and downloaded SHA-256.
- [ ] Verify Sparkle signature and top appcast item from a fresh public response.
- [ ] Installation/relaunch remains a separate gate.

## Current verdict

2026-09-07: **SIGNED, NOTARIZED AND STAGED — PUBLICATION PENDING (user-run upload)**. Merged tree tested (578/0), universal Developer ID export, stapled DMG accepted by Gatekeeper, Sparkle entry signed and verified, page and appcast staged byte-exact. Nothing has been uploaded; the installed 3.5.1 is untouched.
