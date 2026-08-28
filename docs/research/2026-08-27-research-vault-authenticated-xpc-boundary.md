# Research Vault — authenticated XPC boundary evidence packet

Date: 2026-08-27  
Project: Throttle  
Decision: **GO for local scaffold; NO-GO for signed cross-app delivery**

## Executive answer

The strongest supported production boundary is a query-only named XPC service
whose client and server mutually pin Apple code-signing requirements. Grants
must be attached to a dedicated endpoint and never decoded from a request.
Throttle keeps ingestion and keys; CheatCode receives bounded, provenance-rich
results through a DTO-only package surface.

The previous stdio helper remains useful only as a Debug integration harness.
Its direct Release path is now disabled.

## Local research reused

- Title: *Throttle Research Vault × CheatCode — dossier de décision FULL SOTA*
- DeepSearsh path:
  `library/market-and-competitors/deepsearsh/2026-08-27-throttle-research-vault-cheatcode-full-sota--6c9c61119a.md`
- Origins:
  `/Users/kevinnadjarian/GitHub/DeepSearsh/inbox-archive/2026-08-27-throttle-research-vault-cheatcode-full-sota.md`;
  `/Users/kevinnadjarian/GitHub/Throttle/docs/research/2026-08-27-throttle-research-vault-cheatcode-full-sota.md`
- SHA-256:
  `6c9c61119a3627fc1272a8dcd2dafdb452d8a7938a7ce374c1c6f38157d4a93e`

That packet established the local-first vault, one-SQLite-core invariant and
process separation. It was used as context, not as current API proof.

## Focused research plan executed

Questions:

1. Is there a public macOS API to authenticate XPC peers without private audit
   token access?
2. Can invalid peers be rejected before the service delegate handles them?
3. How should grants be mapped when different clients require different scopes?
4. What is the minimum shareable package that cannot pull SQLCipher into
   CheatCode?
5. Which citation fields are still missing from the evidence-first pipeline?

Source classes used: current macOS 27 SDK headers, Apple Foundation/XPC and
Code Signing documentation, current Throttle package source/tests, and the
read-only CheatCode review. No third-party XPC wrapper was needed.

Out of scope: installing a LaunchAgent, changing CheatCode, signing,
notarization, App Store Connect and production Keychain migration.

## Evidence ledger

| Label | Finding | Evidence and limitation |
|---|---|---|
| VERIFIED | `NSXPCConnection.setCodeSigningRequirement` is public on macOS 13+ and invalidates a connection whose peer does not satisfy the requirement. | [Apple API](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)); macOS 27 SDK `NSXPCConnection.h`. Runtime rejection still needs a signed test. |
| VERIFIED | A named/anonymous listener can reject peers before its delegate using `setConnectionCodeSigningRequirement`. | [NSXPCListener](https://developer.apple.com/documentation/foundation/nsxpclistener); current SDK header. Runtime rejection still needs a signed test. |
| VERIFIED | Apple explicitly identifies restricting XPC clients as a use case for code-signing requirements. | [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). |
| VERIFIED | XPC is intended to mediate shared resources and narrow privileges across process boundaries. | [XPC overview](https://developer.apple.com/documentation/xpc). |
| VERIFIED | Xcode's Developer ID/MAS designated requirement pins Apple trust, signing identifier and Team ID using documented certificate OIDs. | [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). Exact signed artifacts must still be inspected. |
| VERIFIED | The local Swift package compiles an equivalent requirement with Security.framework and rejects injected identifier/team components. | `ResearchVaultXPCTests`; this is syntax/policy proof, not signed runtime proof. |
| VERIFIED | The query DTO has no project, sensitivity, key or path fields. | `ResearchVaultIPCModelTests`. |
| VERIFIED | Citation v2 binds the returned excerpt to its own SHA-256 and carries observation/source times plus index generation. | Gateway and SQLCipher tests. Evidence status remains unassessed for imported documents unless explicitly supplied later. |
| OPEN | Whether the final Developer ID and MAS CheatCode artifacts share the intended compatibility requirement. | Requires fresh signed artifacts for both lanes. |
| OPEN | Whether one shared launchd deployment topology satisfies sandbox and Keychain constraints for both products. | Requires Xcode targets, entitlements and signed runtime tests. |

## Architecture selected

```text
Throttle ── signed owner XPC (sealed DTO only) ──> Research Vault SQLCipher
    |                                                ^
    └── signed query XPC + local Workbench ──────────┤
                                                     |
CheatCode ── signed read-only query XPC ─────────────┘

Debug MCP ── direct local harness only (Release disabled)
```

The service maps
`com.kevinnadjarian.cheatcode` + Team `TDV6D5L785` to explicit
`cheatcode`/`throttle` + `internal` access. The request cannot widen it.

## Implemented local slice

- `ResearchVaultIPCModel`: DTOs and citation contract only; no SQLCipher,
  Keychain or ingestion dependency.
- `ResearchVaultXPCClient`: client-only protocols, code-requirement validation,
  reciprocal pinning and bounded short-lived calls; no privileged dependency.
- `ResearchVaultXPC`: server-only query/owner listeners and sanitized dispatch.
- `research-vault-xpc-service`: argument-free named-service scaffold owning
  Keychain/SQLCipher in a separate process.
- SQLCipher schema v3: observation time, optional evidence status and monotonic
  FTS generation.
- direct stdio MCP disabled in Release.
- owner imports are a single SQLCipher transaction after complete grant/hash/
  conflict preflight; paths and caller-selected grants are absent from the DTO.
- Throttle Workbench source provides encrypted health, cited retrieval, sealed
  receipt import, a persistent security-scoped Finder Inbox and on-device MLX
  synthesis marked as generated rather than evidence.
- synthesis output must be bounded JSON with known citation identifiers. The
  private Proxmox provider is intentionally disabled until its service identity
  is authenticated; network locality alone is not sufficient.

## Gates

Local acceptance:

- Debug tests and full package verification green;
- Release build/tests green;
- schema v2 → v3 migration and backup/restore green;
- XPC requirement syntax/injection tests green;
- `git diff --check`, secret scan and negative dependency checks green.

Production acceptance remains blocked on signed runtime identity, launchd/Xcode
registration, Keychain/sandbox entitlements, reciprocal rejection, double-SQLite
runtime attribution and CheatCode-side read-only adoption review.

## Fresh Xcode packaging evidence — 2026-08-27 18:16 Europe/Paris

- `ResearchVaultAgent` is an Xcode application target embedded at
  `Throttle.app/Contents/Library/LoginItems/ResearchVaultAgent.app`.
- The matching launchd property list is embedded at
  `Contents/Library/LaunchAgents/com.lorislab.throttle.research-vault-agent.plist`;
  `BundleProgram` resolves to the nested executable. The current plist declares
  separate CheatCode-query, Throttle-query and Throttle-owner services.
- A fresh unsigned Release build of the complete 104-target Throttle graph
  passed with Xcode 27 beta after explicitly allowing the already-pinned MLX
  package plugin and macro for this local build.
- `Scripts/verify-research-vault-bundle.sh` passed on that exact bundle:
  Throttle links system `libsqlite3` through its existing GRDB stack but not
  SQLCipher; the agent links bundled SQLCipher and not system `libsqlite3`.
- The agent's SQLCipher framework is inside its own `Contents/Frameworks`, not
  Throttle's framework directory.
- `ResearchVaultServiceManager` exposes explicit register/unregister/status;
  no automatic registration or launch was performed.
- The provider-neutral synthesis router passed four policy tests: confidential
  and restricted evidence never reaches the private server, an unauthenticated
  server is rejected, same-device fallback is preferred, and cited retrieval
  remains available without a model.
- Full `ResearchVaultKit/Scripts/verify.sh` passed after these changes: Debug
  and Release suites, IPC dependency gates, crash recovery, DeepSearsh live
  benchmark/MCP checks, and Release fail-closed stdio checks.
- `security find-identity -v -p codesigning` reported zero valid identities.
  Therefore `--require-signed`, launchd registration and peer-rejection runtime
  tests were correctly not claimed or attempted.

## Fresh local evidence — 2026-08-27 17:00 Europe/Paris

- Debug: 29 XCTest + 20 Swift Testing, zero failure.
- Release: 29 XCTest + 20 Swift Testing, zero failure.
- Debug and Release process crash probes: committed rows retained,
  uncommitted writes rolled back, interrupted migration returned to schema 0.
- DeepSearsh snapshot: catalog
  `c5d7c40b89cf2dada0b79f6ca2c039993062f57b42608f2991132b091a43ee03`,
  41 authorized Throttle documents and 460 chunks.
- Retrieval: Recall@5 `1.0`, MRR `0.8667`, nDCG@5 `0.90`; process CPU p95
  `16.706 ms` under host load average `202.45` on 10 active processors.
- Wall p95 was `731.93 ms` and is explicitly **not valid as an operational SLO
  measurement** because the host was saturated. A fresh idle-host wall gate is
  still required; the earlier pre-saturation local measurement was 26.94 ms.
- Real Debug MCP process: 41 documents/460 chunks, citation schema v2 and
  excerpt hash verified.
- Release service XPC product builds; `otool` shows SQLCipher.framework and no
  direct `/usr/lib/libsqlite3` dependency; SQLite symbols resolve from
  SQLCipher.
- Release direct stdio and the Debug-only key flag both return exit 1.
- DeepSearsh global verification: `PASS`, 1,963 documents, 2,198 available
  source paths and no error.
- Gitleaks on sources, tests, ADRs and research: no leak; `git diff --check`:
  clean.

These are local source/build/bundle facts. The signed XPC peer rejection,
launchd registration, Keychain sandbox behavior and cross-app runtime remain
`OPEN` and keep production delivery `NO-GO`.

## Remediation continuation — 2026-08-27 19:45 Europe/Paris

- `ResearchVaultXPCClient`, `ResearchVaultXPC` and
  `ResearchVaultServiceRuntime` compile under Swift 6 strict concurrency.
- 7/7 XPC policy/owner-dispatch tests pass.
- 2/2 fresh SQLCipher owner tests pass: unauthorized batch rollback and
  identical in-batch idempotence.
- The synthesis security probe passes same-device routing plus rejection of an
  invented `S99` citation.
- XcodeGen regenerated the project after adding the client-only and synthesis
  products to Throttle.
- Full app, XCTest, bundle and signed runtime gates must be rerun: the previously
  available `/Applications/Xcode-beta.app` disappeared during the remediation,
  and the remaining Command Line Tools has a mismatched Swift 6.4 compiler/SDK
  and no XCTest runtime. Earlier Release/bundle evidence is therefore stale for
  the new Workbench changes, not silently reused.

## Signed runtime closure — 2026-08-28 Europe/Paris

- The service lifetime no longer calls `dispatch_main()` from an async
  cooperative thread. It suspends until structured cancellation and retains all
  listeners for that lifetime; the regression test proves suspension and clean
  cancellation.
- Live Apple Development signing exposed a missing certificate-policy branch:
  the authorized leaf carries `1.2.840.113635.100.6.1.12`. The reciprocal
  requirement now accepts that development OID in addition to Apple
  distribution and Developer ID Application, without relaxing anchor,
  identifier or Team ID pinning.
- An isolated Apple Development bundle passed deep signature and bundle checks.
  Its temporary launchd agent returned health and bounded owner errors to the
  authorized Throttle peer, rejected the wrong identifier, and rejected a
  Throttle peer on the CheatCode endpoint.
- A signed app-hosted Workbench test window issued a real XPC search and received
  the expected empty-vault response rather than the fail-closed signing error.
  The host used the existing XCTest background-service isolation and never
  replaced or stopped `/Applications/Throttle.app`.
- Fresh full verification passed in Debug and Release, including the MCP
  subprocess, crash/migration probes and Release-only negative gates. The live
  DeepSearsh snapshot contained 44 authorized documents and 490 chunks; Recall@5
  was `1.0`, MRR `0.8667` and nDCG@5 `0.90`. The final post-hardening run had
  process CPU p95 `9.058 ms`; its wall p95 `40.55 ms` is explicitly invalid as
  an SLO sample because host load average was `42.36`. The immediately preceding
  full run recorded a valid wall p95 `5.55 ms` under lower load.
- Cleanup was fail-closed: the temporary launchd service and Launch Services
  registrations were removed, and no process from the final Workbench copies
  remained. This closes local signed runtime proof only; device, cross-app and
  distribution gates remain separate.
