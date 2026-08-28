# ADR-0002 — Authenticated XPC trust boundary

- Status: Accepted for local implementation; distribution proof pending
- Date: 2026-08-27
- Scope: Throttle Research Vault query access from CheatCode and future local clients

## Context

The first standalone `research-vault-mcp` process removed the double-SQLCipher
linkage hazard, but did not authenticate its caller. A process could select
projects and maximum sensitivity through command-line arguments, trigger
Keychain access and perform ingestion during startup. The CheatCode review
therefore classified the process boundary as architecturally useful but the
cross-app delivery as `NO-GO`.

Current macOS Foundation exposes public peer-validation APIs:

- `NSXPCConnection.setCodeSigningRequirement(_:)` validates the peer and
  invalidates the connection when later messages do not match;
- `NSXPCListener.setConnectionCodeSigningRequirement(_:)` rejects invalid
  incoming peers before calling the listener delegate for named or anonymous
  listeners;
- Apple TN3127 explicitly recommends code-signing requirements to restrict an
  XPC service to specific clients and documents the Xcode Developer ID / Mac
  App Store requirement shape.

Primary references:

- [NSXPCConnection.setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [NSXPCListener](https://developer.apple.com/documentation/foundation/nsxpclistener)
- [TN3127: Inside Code Signing — Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [XPC framework overview](https://developer.apple.com/documentation/xpc)
- [Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

The checked SDK is macOS 27.0. Its public Foundation header declares both
methods as available on macOS 13 and later. Throttle targets macOS 14.

## Decision

1. Production vault access uses a named, launchd-owned XPC service. Stdio is a
   Debug integration harness only and is disabled in Release.
2. The query endpoint exposes only `search` and secret-free `health`. It has no
   ingestion, backup, restore, key, path, grant or capability method.
3. Every endpoint instance has exactly one code-signing requirement and one
   immutable `VaultAuthorization`. Requests contain no project or sensitivity.
4. The listener validates the client before its delegate receives a connection.
   The client must reciprocally pin the service requirement before activation.
5. Requirements are built only from validated signing identifier and Team ID
   components, then compiled with `SecRequirementCreateWithString` before they
   are passed to Foundation. Malformed requirements fail startup.
6. The initial query identity is `com.kevinnadjarian.cheatcode`, Team
   `TDV6D5L785`. Its endpoint is explicitly scoped to the `cheatcode` and
   `throttle` projects up to `internal` sensitivity. This mapping is code-owned,
   not request-owned.
7. Throttle-owned ingestion uses a separate owner-only protocol and Mach
   service. It accepts bounded sealed receipt DTOs only; paths, bookmarks,
   keys, grants and capabilities are forbidden. It is never added to a query
   endpoint.
8. Cross-app consumers link only `ResearchVaultIPCModel` and, where useful,
   `ResearchVaultXPCClient`. They must never link
   `ResearchVaultGateway`, `ResearchVaultSQLCipher`, `ResearchVaultKeychain` or
   `ResearchVaultIngestion`.
9. The reciprocal requirement accepts Apple Development
   (`1.2.840.113635.100.6.1.12`), Apple distribution
   (`1.2.840.113635.100.6.1.9`) and Developer ID Application
   (`1.2.840.113635.100.6.1.13`) leaves, while retaining the Apple generic
   anchor, exact signing identifier and exact Team ID checks. This permits the
   isolated signed-development matrix without weakening production identity
   pinning.

## Citation contract v2

Query results now include:

- document and chunk identity;
- exact locator and SHA-256 of the returned excerpt;
- plaintext document SHA-256;
- observation and source-modification times;
- optional evidence status (`nil` means unassessed, never implicitly verified);
- retrieval index generation;
- scoped origins filtered during DeepSearsh import.

Schema v3 adds an observation timestamp, optional evidence status and a
monotonic document-FTS generation. Existing v2 rows backfill observation time
from source modification time; they require a fresh re-import before that value
can be treated as an exact observation timestamp.

## Rejected alternatives

- **PID-only validation:** rejected because process identifiers are not durable
  code identity and invite time-of-check/time-of-use errors.
- **Caller-provided token, project or sensitivity:** rejected as a confused
  deputy design.
- **One broad endpoint plus caller-declared identity:** rejected because the
  request would influence authorization.
- **Direct stdio in Release:** rejected because any local process could launch
  it and there is no authenticated peer channel.
- **Importing SQLCipher modules into CheatCode:** rejected because it restores
  the double-SQLite symbol risk that the process boundary was designed to remove.

## Local evidence and remaining gates

Locally implemented and testable:

- pure, versioned, bounded IPC DTO product;
- requirement-component injection rejection;
- Security.framework compilation of the Apple distribution requirement;
- listener and client reciprocal requirement configuration;
- query-only XPC object with sanitized errors;
- argument-free XPC service scaffold;
- Release fail-closed direct MCP;
- citation contract v2 and SQLCipher schema v3.
- Xcode LaunchAgent packaging with the agent app nested under
  `Contents/Library/LoginItems`, its plist under
  `Contents/Library/LaunchAgents`, and SQLCipher embedded only in the agent;
- explicit `SMAppService.agent(plistName:)` lifecycle management with no
  automatic registration;
- provider-neutral synthesis routing across cited retrieval, same-device MLX
  and an authenticated private server, with sensitive evidence forced to the
  same device or retrieval-only.
- distinct CheatCode query, Throttle query and Throttle owner Mach services;
- atomic owner batch preflight/commit and idempotent in-batch duplicates;
- a client-only dependency closure with reciprocal pinning, response bounds,
  contract-version checks, timeout and one-shot connections;
- a local Workbench with source cards, security-scoped Finder Inbox and an
  on-device MLX draft visibly separated from evidence;
- grounded synthesis execution that rejects uncited/unknown citation IDs.

The existing Proxmox/Ollama worker is not considered authenticated for Research
Vault merely because it is private or reachable over a tailnet. Its adapter
remains disabled until the exact deployment proves mTLS or an equivalently
service-bound credential. Public/internal routing policy is necessary but does
not itself prove transport identity.

Still `NO-GO` for production delivery until all of these are fresh and green:

1. signed Developer ID and Mac App Store Throttle/service artifacts, plus a
   signed CheatCode client, with exact designated
   requirements inspected from the artifacts;
2. negative runtime clients: ad-hoc, wrong Team ID, wrong signing identifier,
   debug entitlement and malformed requirement;
3. reciprocal service-identity rejection from CheatCode;
4. Keychain access group and App Sandbox behavior in both distribution lanes;
5. link-map, `dladdr(sqlite3_open_v2)` and dyld-image evidence on both
   signed processes;
6. launchd registration, crash/reconnect, concurrent reader/owner, update and
   rollback tests on the signed nested bundle;
7. no installation, signing, notarization or CheatCode source change before an
   explicit authorization gate.

## Consequences

The new package surface is structurally safe to review and consume without a
second SQLite core. It is not yet a shipped integration: a SwiftPM build proves
source compatibility, not launchd registration, code identity, sandbox access,
device runtime or distribution readiness.
