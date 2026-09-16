# Mirror read contract — local extraction evidence

Date: 2026-09-16. Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Worktree: `build/workflow-contracts-8a91a20b`, branch
`codex/workflow-contracts-8a91a20b`, base
`0f53c96882d8ad4caaf07c27efe0b052421999ef` with preserved local changes.
Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4.

## Boundary and compatibility

The new independent `ThrottleMirrorContract` package owns `MirrorReadSnapshot`,
`WindowMirror`, `TabMirror` and `SessionStateMirror`. It imports only Foundation
and has no package dependencies. The read snapshot exposes eleven display keys;
none of the five provisioning fields can be retained or re-encoded by its codec.

`ThrottleShared.ThrottleMirrorSnapshot` now composes the read snapshot with
`MirrorProvisioning`. Pairing secret, fallback host, Edge host/port and Edge token
stay in this product module. Compatibility aliases, initializer arguments and
readable properties remain available. The custom encoder/decoder keeps the old
flat JSON; there are no nested read/provisioning keys and no schema-version bump.
This is source/wire compatibility after rebuilding, not binary ABI compatibility.

The existing `withoutSecrets` behavior is preserved: both credentials disappear,
endpoint metadata remains. `readSnapshot` excludes all provisioning. The existing
outbound scrubbing extensions stay in the product. Free-form display strings
still require that policy; the public type is not itself a redaction engine.
No CloudKit schema, live transport channel or storage migration is performed.

A synthetic full envelope was encoded by the original implementation before
editing; original sources and capture are retained in
`/private/tmp/throttle-mirror-baseline-20260916/`. The fixed full JSON fixture is
`ThrottleShared/Tests/ThrottleSharedTests/Fixtures/pre-extraction-mirror.json`.
Its read-only projection is the standalone package's fixture. Tests compare
JSON objects rather than incidental key ordering. Fixtures contain no real secrets.

## Validation

| Check | Result | Evidence |
|---|---|---|
| `swift test --package-path ThrottleShared --jobs 1` | PASS: 40 shared XCTest + 20 peer XCTest + 3 Swift Testing cases, zero failures | `/private/tmp/throttle-mirror-shared-20260916-final.log` |
| Standalone copy, `swift test --package-path /private/tmp/throttle-mirror-isolated-20260916-9uemgbqk --build-system native --jobs 1` | PASS: 5 tests | `/private/tmp/throttle-mirror-isolated-20260916.log` |
| `python3 -m unittest discover -s scripts/tests -p test_macos_evidence.py` | PASS: 34 tests | Terminal result |
| SwiftLint 0.65.1 strict, no cache, nine affected Swift files | PASS: 0 violations | `/private/tmp/throttle-mirror-lint-20260916-final.log` |
| iOS arm64 transport dependency build | PASS: contract and shared envelope compile for iOS; transport target completes | `/private/tmp/throttle-mirror-ios-build-20260916.log` |
| `git diff --check` | PASS | Local diff check |

iOS command (no signing or installation):

```sh
swift build --package-path ThrottleShared --target ThrottlePeer \
  --triple arm64-apple-ios17.0 \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk \
  --jobs 1
```

Six new shared tests cover full-envelope JSON compatibility, read projection,
legacy disk projection, absent/null provisioning, encrypted CloudKit mapping and
outbound scrubbing before read projection. Existing tests also retain ordinary
snapshot round trips, terminal framing, pairing and secret hygiene checks.
CloudKit record mapping tests do not contact the service.

The five standalone tests cover display JSON compatibility, all five provisioning
fields being dropped (including malformed unknown values), preserved unknown
versions/states, rejected malformed required data and the exact read key set.
The isolated copy uses a six-file allowlist, recorded with SHA-256 hashes in
`/private/tmp/throttle-mirror-isolation-20260916.json`. This proves dependency
independence outside the checkout, not an OS-enforced isolation boundary.

Both native source-evidence profiles now hash the contract package; the Python
regression test verifies changed and missing sources for macOS and iOS. CI adds
the standalone contract suite before the existing shared tests.

The first shared build found the missing direct module import for the moved
`TabMirror` extension; it was corrected before the passing run. Initial and final
logs are retained. The isolated native SwiftPM build emits the existing build
system deprecation warning; no checks were weakened.

## Remaining gates

The app-hosted full Xcode suites, exact CI with pinned SwiftLint 0.63.2, runtime
and physical-device journeys still need revalidation on the final dependency
graph. Local unit/mapping/build results do not close those gates or prove a
public release. Rights qualification and versioned package publication remain
open. No commit, push, installation, signing or publication occurred in this slice.

Next: audit the client dependency closure of the Vault IPC contracts before
extracting their public types. Keep storage, gateway and key handling in the product.
