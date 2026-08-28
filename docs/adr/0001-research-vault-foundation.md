# ADR-0001 — Research Vault foundation

- Status: Accepted for implementation
- Date: 2026-08-27
- Scope: Throttle and a future opt-in CheatCode adapter

> IPC note: the standalone stdio boundary described below is superseded for
> production cross-app access by ADR-0002. It remains a Debug harness only.

## Context

Throttle already indexes provider transcripts and exposes MCP tools. DeepSearsh
already maintains a useful local research library. CheatCode already owns a
SQLCipher/FTS5/sqlite-vec stack. None of those stores is a canonical,
provider-neutral research record with explicit provenance and policy decisions.

The full evidence and alternatives are recorded in
`docs/research/2026-08-27-throttle-research-vault-cheatcode-full-sota.md`.

## Decision

1. `ResearchVaultKit` is a standalone Swift package. Its public model is the
   compatibility boundary between Throttle and future consumers.
2. A sealed `ResearchReceipt` is the stable agent/session output. Provider
   transcripts are untrusted candidates, not accepted knowledge.
3. Receipt identity uses canonical JSON and SHA-256. The hash excludes the
   `contentHash` field itself and includes every other receipt field.
4. Retrieval and storage authorization is fail-closed. Every operation carries
   an explicit set of project keys and a maximum sensitivity.
5. Re-importing an identical receipt is idempotent. Reusing a receipt ID with
   different content is a hard conflict.
6. Sources require a stable ID, locator, observation time and plaintext SHA-256.
   Findings may only cite source IDs present in the same receipt.
7. The first production retrieval baseline is FTS5/BM25. Semantic retrieval is
   a challenger and may only be promoted by the versioned golden evaluation.
8. The production store will use one SQLCipher core, encrypted object storage,
   Keychain-backed per-vault keys, transactional migrations and encrypted
   backups. No plaintext fallback is permitted.
9. Throttle and CheatCode may share package code, never vault keys or corpus.
10. The shared core is the official Zetetic `SQLCipher.swift` 4.18.0 binary
    package. A consuming process must not also link CheatCode's amalgamation or
    another SQLite implementation for Research Vault access. Adoption requires
    a fresh link-map/runtime identity check and reproduction of the BSD notice.

## Invariants

- No implicit wildcard project access.
- No sensitivity downgrade during import or retrieval.
- No source instruction can grant capabilities or promote a candidate.
- No raw document, key, prompt, or transcript in diagnostic logs.
- Derived indexes are disposable and reproducible from accepted encrypted data.
- Invalid, ambiguous or unsupported schema versions fail closed.

## Implemented foundation

The package now contains the model, canonical receipt validator, policy engine,
encrypted object store, Keychain root key, official SQLCipher persistence,
transactional schema v2, encrypted backup/restore, crash probes, verified
DeepSearsh ingestion, Finder receipt inbox, deterministic Markdown chunks,
BM25 retrieval evaluation and a fixed-authorization Gateway.

The Gateway is the only app/MCP boundary: it returns bounded excerpts with
document ID, library path, origins, chunk ordinal and plaintext SHA-256. It does
not generate a synthetic source of truth. Throttle app wiring follows package
verification. CheatCode remains unchanged until its session reviews the
adoption handoff and resolves the one-SQLite-core rule, preferably through a
local IPC adapter first.

The initial process boundary was the standalone `research-vault-mcp` helper.
Throttle's existing GRDB/system-SQLite process must not link the SQLCipher
XCFramework. The helper proved process isolation, but its stdio transport did
not authenticate callers. ADR-0002 therefore disables direct Release stdio and
moves production access to a signed, query-only XPC service with immutable
endpoint grants. Embedding or installing that service remains a separate
signing and distribution gate.

## Consequences

This adds deliberate work before UI value appears, but prevents three costly
failures: duplicating storage code, coupling knowledge to provider transcripts,
and treating RAG output as a source of truth.
