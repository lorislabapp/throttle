# Vault client (transport/SDK) — local extraction evidence

Date: 2026-09-16. Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Worktree: `build/workflow-contracts-8a91a20b`, branch
`codex/workflow-contracts-8a91a20b`, base
`0f53c96882d8ad4caaf07c27efe0b052421999ef` with preserved local changes.
Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4. Runtime: Claude Code.
Follows `2026-09-16-vault-contract-extraction.md`.

## Boundary

`Packages/ThrottleVaultClient` (macOS 14 only: mach-service XPC and Code
Signing Services do not exist on iOS) depends on `ThrottleVaultContract` alone
and re-exports it. It owns, moved byte-for-byte apart from imports:

- the two `@objc` NSXPC interfaces (`ResearchVaultQueryXPCProtocol`,
  `ResearchVaultOwnerXPCProtocol`), `ResearchVaultCodeRequirement` and
  `ResearchVaultXPCConnectionFactory` (`ResearchVaultXPCInterface.swift`);
- the secretless one-call `ResearchVaultClient` actor, its error type and the
  `makeCheatCodeClient()` constructor (`ResearchVaultClient.swift`);
- the Inbox `ResearchVaultReceiptBatchReader` (pure client-side file reading).

The product module `ResearchVaultXPCClient` now re-exports the package with
`@_exported import` and keeps only `ResearchVaultQueryEndpointPolicy`,
`ResearchVaultOwnerEndpointPolicy` and their name check: they bind a mach
service to an immutable `VaultAuthorization` grant, which no client may build
or send. The XPC service (`ResearchVaultXPC`), the service runtime and the app
compile unchanged through the re-export; `project.yml` is untouched.

The previous note kept the NSXPC protocols in the product because moving them
changes their Objective-C runtime name. Measured before/after:
`ResearchVaultXPCClient.ResearchVaultQueryXPCProtocol` became
`ThrottleVaultClient.ResearchVaultQueryXPCProtocol` (same for the owner
interface). The selector lists are identical to the capture. NSXPC decodes an
incoming message by selector against the receiver's exported interface, and
the app and its helper ship in one bundle, so no installed pairing depends on
the runtime name. This is a source/wire compatibility statement after
rebuilding, not a binary ABI promise; real mach XPC between the app and the
helper was not exercised in this slice.

The owner-capability scan of `verify-ipc-boundary.sh` still applies to the
contract only; the client package gets its own two scans: no product module
import at all, and no grant, endpoint policy, database path, master key or
Keychain item API. A first, broader pattern matched the word "SQLCipher" in a
doc comment and was tightened to API names before the passing run.

## Compatibility capture

Before editing, the original `ResearchVaultXPCClient` module (same baseline
package as the contract lot) produced
`Packages/ThrottleVaultClient/Tests/ThrottleVaultClientTests/Fixtures/pre-extraction-xpc-interface.json`:
the required instance selectors of both interfaces, their runtime names and the
receipt file suffix. The client package test recompares the selectors and the
suffix and prints the new runtime names.

## Validation

| Check | Result | Evidence |
|---|---|---|
| `swift test --package-path Packages/ThrottleVaultClient --jobs 1` | PASS: 6 XCTest + 2 Swift Testing cases | `scratchpad/logs/client-tests-final.log` |
| Isolated copy of contract + client outside the checkout, `swift test --build-system native --jobs 1` | PASS: 6 + 2 cases; 25-file SHA-256 manifest | `scratchpad/logs/isolated-client-tests.log`, `scratchpad/isolated/isolation-manifest-client.txt` |
| `swift build --package-path Packages/ResearchVaultKit --target ResearchVaultXPC --jobs 1` (service module and its full closure: gateway, SQLCipher, ingestion, reasoning, store, client, contract) | PASS, 0 errors | `scratchpad/logs/kit-xpc-service-build.log` |
| `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh` (contract + client scans) | PASS | Terminal result |
| `scripts/verify-research-vault-dependencies.sh` | PASS | Terminal result |
| Python `test_macos_evidence.py` / `test_vault_evidence.py` | PASS: 36 / 46 tests (a first run concurrent with file copies and the build reported 1 failure / 2 errors; the clean re-run passed) | Terminal result |
| SwiftLint 0.65.1 strict, no cache, 8 touched Swift files | PASS: 0 violations | `scratchpad/logs/lint-client.log` (final run) |
| `git diff --check` | PASS | Local diff check |

Client tests cover: selector and suffix equality with the capture; the Apple
distribution requirement compiles and a malformed one is refused; the factory
pins the query and owner interfaces without activating a connection; a
query-only client refuses every owner operation before connecting; oversized
or invalid queries are refused by the contract before any connection; a missing
mach service fails closed as `serviceUnavailable`. No live vault service is
contacted. The moved Inbox reader tests keep their symlink, duplicate, size and
batch refusals.

Validators updated: `verify-macos-evidence.py` adds the package to the macOS
fingerprint with a regression test; `verify-vault-tests.py` includes it in the
vault source snapshot; CI runs the standalone suite after the contract suite.

## Remaining gates

The product package's own test targets were built (`swift build --build-tests`,
SQLCipher framework staged as in `Scripts/verify.sh`) and the touched targets
ran green: `ResearchVaultXPCTests` 19 cases (trust policy, wire envelope,
in-process owner dispatch) and the IPC model re-export test
(`scratchpad/logs/kit-focused-tests.log`). The complete package suite was
started afterwards and was killed by the system for low memory after 72
Swift Testing cases and several XCTest bundles had passed with zero failures
(`scratchpad/logs/kit-full-tests.log`); it is not a complete run and must be
repeated on a machine with free memory.
The macOS and iOS app targets,
Xcode resolution of the two nested packages, real mach XPC, the pinned
SwiftLint 0.63.2 ratchet and exact CI remain to run on this revision. A thin
CLI and integration examples are not written: nothing here could exercise them
against a live service without relaunching the app. Rights qualification,
notices, version pinning and repository separation remain open. No commit,
push, installation, signing or publication occurred.

Next: CLI and examples on this client, then the remaining boundaries listed in
`docs/ip/component-split.md`.
