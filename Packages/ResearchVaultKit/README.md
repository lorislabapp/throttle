# ResearchVaultKit

Provider-neutral, local-first research storage shared by Throttle and future
opt-in consumers. This package contains no user corpus, vault key or model.

## Products

- `ResearchVaultModel`: receipts, provenance evidence and authorization policy.
- `ResearchVaultStore`: reference receipt store and AES-GCM object store.
- `ResearchVaultSQLCipher`: official SQLCipher 4.18 runtime and persistent store.
- `ResearchVaultKeychain`: non-synchronizable device-bound root key storage.
- `ResearchVaultIngestion`: verified DeepSearsh snapshots, Markdown chunking,
  Finder receipt inbox and retrieval evaluation.
- `ResearchVaultIPCModel` and `ResearchVaultXPCClient`: SQLCipher-free protocol,
  canonical service identity and a least-privileged query-only CheatCode client.
- `ResearchVaultGateway`: fixed-authorization Workbench/MCP boundary returning
  bounded excerpts with source path, origins and plaintext hash.
- `ResearchVaultMCP`: typed JSON-RPC/MCP protocol handler with the read-only
  `research_vault_search` and `research_vault_health` tools.
- `research-vault-mcp`: isolated stdio server using Keychain-derived keys in
  production, so Throttle/GRDB and SQLCipher never share one process.

## Data flow

1. Agents atomically rename canonical `*.research-receipt.json` files into a
   Finder-visible inbox. Invalid or partial entries block the batch.
2. DeepSearsh remains read-only. `catalog.jsonl`, every selected file, size,
   path confinement and SHA-256 are verified before import.
3. Accepted documents and chunks are stored in SQLCipher. Project and
   sensitivity predicates run inside SQL before plaintext results are returned.
4. `ResearchVaultGateway.context` creates a local, citation-first context bundle
   for Throttle, MCP or an on-device model. It does not synthesize claims and
   never uploads the corpus.

The package is the local NotebookLM-like evidence engine, not an oracle: model
answers remain derived output and citations remain the authority.

## Consumer boundary

Use `ResearchVaultGateway` from one owning process. A consumer supplies a
32-byte database key derived from the Keychain master key and constructs one
immutable `VaultAuthorization`. Never accept project keys or sensitivity limits
from tool-call input.

CheatCode adoption is opt-in and must first resolve its existing SQLite linkage:
the same process must not load both its SQLCipher amalgamation and this official
SQLCipher XCFramework. A local IPC adapter is the safest initial integration
because it shares schemas and citations without sharing keys or database files.
CheatCode should construct its client with
`ResearchVaultServiceContract.makeCheatCodeClient()`; this pins the canonical
helper identifier and Team ID and intentionally provides no owner/import route.

## Verification

Run:

```sh
Scripts/verify.sh
```

Build an unsigned, non-overwriting helper bundle for later signing/embedding:

```sh
Scripts/package-mcp-helper.sh /absolute/new/destination/research-vault-mcp
```

The result places `research-vault-mcp` beside `SQLCipher.framework`, includes
third-party notices and records SHA-256 for every packaged file. Packaging does
not install, sign, notarize or register the MCP server.

The script runs all tests in Debug and Release. The explicit framework staging
is required because SwiftPM 6.4 currently places the official dynamic
`SQLCipher.framework` beside XCTest bundles but omits it from their rpath
`PackageFrameworks` directory. App consumers still embed the framework through
their normal Xcode build phase. The workaround copies only the artifact already
downloaded and checksum-verified by SwiftPM.

The Xcode 27 beta default SwiftPM build engine also fails explicit module
discovery for optimized test targets. Release verification temporarily uses the
deprecated native SwiftPM backend and says so in its output; this is an
infrastructure workaround, not product proof to suppress or silently ignore.

The verification also launches a separate crash-probe executable in both
configurations. It terminates with `_exit(86)` after forcing uncommitted pages
into SQLCipher's WAL and during a schema migration. A fresh process must then
prove rollback, schema-version atomicity, `quick_check` and page-HMAC integrity.

When the local DeepSearsh checkout is readable, verification also imports the
current Throttle snapshot into an ephemeral encrypted database and enforces:
Recall@5 = 1.0, MRR >= 0.80, nDCG@5 >= 0.80 and query p95 <= 100 ms.
It then exercises the real stdio MCP process against an ephemeral Debug-only
key and database. The testing-key flag is compiled out of Release and its
rejection is a required gate; production always uses the device-bound Keychain.

Do not replace this dependency with system SQLite: an empty `cipher_version`, a
wrong key, a plaintext file header or a failed integrity check is a hard error.
