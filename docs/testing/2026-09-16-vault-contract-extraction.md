# Vault client contract — local extraction evidence

Date: 2026-09-16. Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Worktree: `build/workflow-contracts-8a91a20b`, branch
`codex/workflow-contracts-8a91a20b`, base
`0f53c96882d8ad4caaf07c27efe0b052421999ef` with preserved local changes.
Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4. Runtime: Claude Code.

## Dependency inventory (before extraction)

| Module | Files | Imports | Consumers |
|---|---|---|---|
| `ResearchVaultModel` | `ResearchReceipt.swift` (receipt format, sealing, validator, `ResearchReviewState`), `VaultAuthorization.swift` | CryptoKit, Foundation | every vault module, Throttle app (21 files), CheatCode bridge |
| `ResearchVaultIPCModel` | six request/response files | Foundation, `ResearchVaultModel` (`ResearchSensitivity`, `ResearchEvidenceStatus`, `ResearchSource`, `ResearchReceipt`, `ResearchReceiptValidator`) | Synthesis, Ingestion, Gateway, XPC, MCP, XPCClient, Throttle app (17 files) |
| `ResearchVaultXPCClient` | NSXPC protocols, `ResearchVaultCodeIdentity`, endpoint policies, code-requirement compilation, connection factory, `ResearchVaultClient`, `ResearchVaultServiceContract`, Inbox batch reader | Foundation, Security, both modules above | XPC service, ServiceRuntime, Throttle app (16 files), CheatCode bridge |

Nothing in the two model modules reaches storage, Keychain, gateway or the
service runtime. `VaultAuthorization` is the immutable endpoint grant used by
the gateway, stores and listener policies; `ResearchReviewState` is storage
state. Both stay in the product. The CheatCode bridge file is listed under
`exclude:` in that package's manifest, so no live external consumer builds
against these modules today; the Throttle app is the only live client.

## Boundary chosen

`Packages/ThrottleVaultContract` now owns, byte-for-byte moved apart from the
removed product import and two explicit lint carry-over comments:

- the sealed receipt format and validator (`ResearchReceipt.swift`, minus the
  storage review state);
- the six IPC request/response files, including `encodedForIPC()` and the
  wire limits in `ResearchVaultIPCContract`;
- `ResearchVaultServiceIdentity.swift`: `ResearchVaultXPCConfigurationError`,
  `ResearchVaultCodeIdentity` (requirement text only) and the
  `ResearchVaultServiceContract` service names, signing identifier and team.

It imports Foundation and CryptoKit only and has no package dependency.
`ResearchVaultModel` and `ResearchVaultIPCModel` re-export it with
`@_exported import`, so the 21 + 17 + 16 product imports, the XPC service and
the internal modules compile unchanged; `ResearchVaultModel` keeps
`ResearchReviewState` and `VaultAuthorization`. `ResearchVaultXPCClient` keeps
the two `@objc` NSXPC protocols, both endpoint policies (they carry the grant),
`ResearchVaultCodeRequirement` (Security framework), the connection factory,
the client actor and the Inbox reader; `makeCheatCodeClient()` becomes an
extension of the contract's `ResearchVaultServiceContract`. The NSXPC protocols
were deliberately left in the product: moving them would change their
Objective-C runtime name and would trip the owner-capability pattern of
`verify-ipc-boundary.sh` on `importReceipts`. They belong to the transport/SDK
extraction, not to the data contract.

`ResearchVaultKit/Package.swift` declares `.package(path: "../ThrottleVaultContract")`;
`project.yml` is unchanged because the app links only `ResearchVaultKit`
products and the nested dependency resolves in SwiftPM, as the mirror contract
already does. The Xcode project was not regenerated in this slice.

## Compatibility capture

Before editing, the original `ResearchVaultModel`, `ResearchVaultIPCModel` and
`ResearchVaultXPCClient` sources were extracted from `HEAD` into an isolated
baseline package (hashes in `scratchpad/logs/baseline-sources-sha256.txt`) and
a capture test serialized synthetic samples of all 18 request/response types
with the product wire codec (sorted keys, unescaped slashes, millisecond
dates), plus the contract constants, the service names and the code requirement
text for a synthetic identity. The result is
`Packages/ThrottleVaultContract/Tests/ThrottleVaultContractTests/Fixtures/pre-extraction-wire.json`,
SHA-256 `94c0685dff7aea8b53253a2244284c8ea0ea0722630222dcfe472dbb30b3f701`.
The same helper source, compiled against the new package, must reproduce every
object; tests compare canonical JSON objects, not key order. The sealed receipt
in the fixture pins the canonicalizer: its `contentHash`
`f8f7b4220c27d813c64874dc9f1a745b6af395a063a55727e1862251928a2c07` is re-derived
by sealing the same payload. Fixtures are synthetic; the only real values are
the public service names and team identifier already in source.

## Validation

| Check | Result | Evidence |
|---|---|---|
| `swift test --package-path Packages/ThrottleVaultContract --jobs 1` | PASS: 9 XCTest + 4 Swift Testing cases | `scratchpad/logs/contract-tests-final.log` |
| Isolated copy outside the checkout, `swift test --build-system native --jobs 1` | PASS: 13 cases; 14-file SHA-256 manifest | `scratchpad/logs/isolated-contract-tests-final.log`, `scratchpad/isolated/isolation-manifest.txt` |
| `swift build --package-path Packages/ResearchVaultKit --target ResearchVaultXPCClient --jobs 1` | PASS (client closure: contract, model, IPC model, XPC client); only the upstream SQLCipher manifest deprecation warning | `scratchpad/logs/kit-xpcclient-build.log` |
| `scripts/verify-core-evidence.py` (exact sources, contract + model + IPC + ingestion + product adapters) | PASS: 257 cases, exit 0/0, no receipt errors; 8 contract sources hashed | `scratchpad/core-evidence/throttle-core-evidence-iu0eicry/receipt.json` |
| `scripts/verify-research-vault-dependencies.sh` | PASS: client closure free of store/key/gateway/SQLCipher targets | Terminal result |
| `Packages/ResearchVaultKit/Scripts/verify-ipc-boundary.sh` (now also scans the contract package for any product import and owner capability) | PASS | Terminal result |
| Python `test_macos_evidence.py` / `test_core_evidence.py` / `test_vault_evidence.py` / `test_ip_inventory.py` | PASS: 35 / 6 / 46 / 6 tests | Terminal result |
| SwiftLint 0.65.1 strict, no cache, 16 touched Swift files | PASS: 0 violations | `scratchpad/logs/lint-final.log` |
| `git diff --check` | PASS | Local diff check |
| `scripts/ip-inventory.py` | 1 227 paths, all `unreviewed`; 14 in the new package; 6 pending tracked deletions recorded as scope issues | `audit-output/ip-inventory-20260916-2.json` |

`scratchpad` = `/private/tmp/claude-501/-Users-kevinnadjarian-GitHub-Throttle/070db455-a540-4e90-8a17-7e8fbbc2d401/scratchpad`
(session-local; copy what must survive).

The client-closure build ran before the two lint carry-over comments were added
to the contract sources; the core validator and both contract suites ran on the
final sources. The XPC client files did not change afterwards.

The four lint violations in the moved sources (parameter count and complexity
in the receipt validator, two guarded force unwraps in the reasoning DTO) were
already accepted by `.swiftlint-baseline.json` at their old paths. They now
carry explicit `swiftlint:disable:next` comments so the pinned 0.63.2 ratchet
does not depend on baseline entries for paths that no longer exist. The moved
IPC model test's baselined trailing comma was fixed instead.

Validators updated: `verify-core-evidence.py` copies and hashes the eight
contract sources and compiles the re-export modules against them;
`verify-macos-evidence.py` adds the package to the macOS source fingerprint
(macOS only, the vault is not in the iOS app) with a regression test;
`verify-vault-tests.py` includes the package in the vault source snapshot; CI
runs the standalone suite before the shared packages. `ip-inventory.py` no
longer aborts on an unstaged tracked deletion: such paths are excluded from the
hashed files and reported as `pending-tracked-deletion` scope issues, with a
test; the inventory stays incomplete and fail-closed.

## Remaining gates

Not rebuilt in this slice, for disk reasons (free space fell to 0.8 GiB during
the run): the service-side modules (`ResearchVaultXPC`, gateway, service
runtime, MCP, executables), the full `ResearchVaultKit` suite with SQLCipher,
the macOS and iOS app targets, and Xcode resolution of the nested package.
Real mach XPC between the app and the helper was not exercised; the in-process
XPC tests were not re-run. The pinned SwiftLint 0.63.2 ratchet and exact CI
remain to run on this revision. Rights qualification, notices, version pinning
and repository separation remain open. No commit, push, installation, signing
or publication occurred.

Next: the transport/SDK layer (NSXPC protocols, code requirement, connection
factory, thin client and CLI) built on this contract, per
`docs/ip/component-split.md`.
