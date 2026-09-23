# Workflow product-lab contracts — lots consolidés et durcissement

Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`  
Base: `0f53c96882d8ad4caaf07c27efe0b052421999ef`  
Worktree: `codex/workflow-contracts-8a91a20b`

## Scope

This increment connects the existing task engine to versioned work, evidence,
review, authority, budget, design and product-cycle contracts. It does not
replace the existing PlanStore, Research Vault, Git integration or provider
adapters. It adds deterministic decisions around them.

The implementation is local and uncommitted. It has not changed a remote,
licence, Apple account, installed app or public release.

## Implemented behavior

| Lot | Behavior now enforced |
|---|---|
| 1 — task and evidence | A worker submits `candidate_complete`. A required test contract is fingerprinted before execution, imported from native results and re-read at integration. Missing, stale, skipped or unknown evidence blocks completion. |
| 2 — instructions and recipes | Applicable `AGENTS.md`/`CLAUDE.md` files are discovered with precedence and symlink refusal. Reconciliation preserves human content, excludes secrets/task state and requires an exact, current review before apply or rollback. Three versioned recipes cover bug regression, native UI and reviewable change. |
| 3 — budgets and capabilities | Admission uses configured units and protected reserves, serializes concurrent reservations and records measured versus upper-bound settlement. MCP grants are root/action/task/mission scoped, expiring and revocable; session close revokes before removal. Provider enforcement fidelity remains explicit. |
| 4 — fidelity and quality | Structured, revision-bound review criteria keep pass, fail, not verified and justified not applicable separate. Critical failures cannot be averaged away. MCP exposes the same review contract. |
| 5 — red team | A private campaign store confines synthetic targets, deduplicates observations and requires triage plus independent retest before a finding can be delivered. It grants no network or production authority. |
| 6 — design | A versioned Design Contract records journeys, states, accessibility and measurable evidence. The cockpit displays the contract and missing verification without claiming an unavailable Claude Design integration. |
| 7 — product cycle | Frozen release manifests, target-specific release gates, dependency ADOPT/ADAPT/WRAP/FORK/BUILD decisions, platform parity, technology reuse and IP/open-source assessments are deterministic and evidence-bound. None performs installation, relicensing or publication. |
| Filesystem-first context | `throttle_project_explore` provides bounded list, exact search and read over one granted root. It rejects path escape and symlink traversal and returns exact path/byte/digest receipts. Structured aggregation remains a future benchmarked SQLite projection. |
| Edge supply chain | Claude Code 2.1.267 is selected by supported architecture, downloaded from an exact versioned path, checked against an embedded SHA-256 in private staging and atomically activated. Auto-update is disabled. |
| CloudKit deletion | Turning the mirror off keeps the last snapshot explicitly. A separate confirmed action deletes the fixed private record idempotently; the iOS subscriber observes deletion and scrubs local surfaces. |

## Release effect journal

Release intent and provider observation are stored separately in a private,
append-only `.throttle/releases/<release-id>.ndjson` journal. Every event is
bound to the frozen manifest and previous line digest. The store uses owner-only
directories/files, refuses symlinks and hard links, serializes writers and
synchronizes each append.

An external effect must follow `prepared → started → observed`:

- `started` requires an unexpired authorization matching the release, manifest,
  action, target, audience and payload digest;
- the target must exist in the frozen manifest;
- a crash after `started` leaves an unresolved effect that must be reconciled
  with the provider before retry;
- a torn final line is corruption and is never silently repaired;
- retrying the exact event is idempotent, including fractional timestamps;
- no provider is invoked by the journal itself.

The hash chain detects accidental edits and partial writes. It is not an
authenticated defense against a process able to rewrite the whole repository.

## Validation on the current sources

| Check | Result | Evidence class |
|---|---:|---|
| Core exact-source verifier | **253/253 passed**, 0 errors | PRODUCT, `core-validator-subset` |
| Release journal targeted suite | **6/6 passed** | PRODUCT, targeted Swift Testing |
| Core verifier self-tests | **6/6 passed** | TEST-HARNESS |
| IP inventory self-tests | **5/5 passed** | TEST-HARNESS |
| macOS `build-for-testing` | **PASS**, 0 errors, 0 warnings | PRODUCT TARGET COMPILE |
| macOS app-hosted suite | **846 total, 841 passed, 5 skipped, 0 failed, 0 runtime warnings** | PRODUCT RUNTIME TEST |
| CloudKit deletion, macOS | **9/9 passed** | PRODUCT TARGETED TEST |
| CloudKit privacy/deletion, iOS simulator | **12/12 passed** | SIMULATOR PRODUCT TEST |
| Edge runtime installation | **14/14 passed** | PRODUCT PACKAGE TEST |
| French catalog in compiled product | **147/147 matched** | COMPILED LOCALIZATION |
| Critical Thread Sanitizer matrix | **30/30 passed, 0 runtime warnings** | BOUNDED PRODUCT TEST |
| Isolated candidate process smoke | **STALE FOR CURRENT DIFF**, predates final Edge/CloudKit edits | RUNTIME PROCESS |
| Cockpit Plan visual/AX journey | **BLOCKED**, Computer Use native pipe failed on 3 attempts | INFRASTRUCTURE |
| Swift parse, release-journal files | PASS | PRODUCT compile front-end |
| SwiftLint strict, all changed Swift | **0 violations across 100 files** | SUPPLEMENTARY |
| XcodeGen | PASS; project regenerated with the new files | PROJECT GENERATION |
| `git diff --check` | PASS | SOURCE HYGIENE |

Core receipt:
`/private/tmp/throttle-core-evidence-20260915-1800-final/throttle-core-evidence-mx84pzg_/receipt.json`.

The current 3.7.0 (221) product and test bundle were compiled for macOS 27.0
arm64 with Xcode 27.0 (27A266a). The machine-readable result is
`/tmp/throttle-sota-qos-build.xcresult`; its build summary is
`succeeded` with zero errors and zero warnings. This proves compilation only.

The same product and test bundle then passed its full app-hosted suite: 846
total, 841 passed, five explicitly skipped live opt-in tests, zero failed and
zero runtime warnings. The native receipt is
`/private/tmp/throttle-sota-macos-tests-20260915-release-ready2.xcresult`. The skipped cases require
external MLX/model, configured Ollama or recorded NotebookLM fixtures; none was
reported as passed. An earlier attempt was invalidated by `ENOSPC` and is not
counted as product evidence. Runtime/AX journeys remain a separate gate.

An earlier ad hoc candidate was also started with `-demo`, an isolated HOME and a
fixture session persisted as hibernated. This bypasses production listeners and
prevents any agent process from launching; it does not install or replace the
published app. It predates the final Edge/CloudKit edits and is therefore stale
for the current diff. Three fresh Computer Use attempts all returned `Sky
Computer Use native pipe startup failed`, so no visual or accessibility claim
is made. The fixture manifest is
`/private/tmp/throttle-workflow-runtime-8a91a20b/fixture-manifest.json`.

## Current limits and open gates

1. The root MIT licence conflicts with current public/commercial scope claims.
   The factual inventory deliberately leaves every path unreviewed until a
   qualified owner/legal decision. No code can resolve that decision.
2. The public default branch remains unprotected and this local work has no
   commit, push or CI evidence.
3. Local SwiftLint is 0.65.1 while the project pin is 0.63.2. The local result
   is supplementary; the exact pinned CI result remains required.
4. The fresh full Xcode product/test-bundle build and app-hosted suite pass.
   Live-provider opt-in tests and the controlled runtime/AX journey remain open.
5. Runtime UI, VoiceOver, keyboard and EN/FR inspection are blocked by the
   unavailable native Computer Use pipe. Physical platform, signed artifact,
   notarization, staple, website and public-state checks are not run.
6. MCP descriptors enforce the cooperative Throttle surface. They are not an
   OS sandbox, credential broker or independent authenticated execution host.
7. The pinned Edge installer still needs a disposable live Debian qualification,
   and CloudKit deletion still needs physical two-account/two-device evidence.
8. SQLite adoption for aggregate knowledge questions requires a Throttle
   benchmark; the supplied Vercel results are a design signal, not product proof.

## Next gated work

Runtime/AX validation is the next local product gate. A qualified IP decision
precedes any release candidate. Commit/push, branch protection, notarization and
publication remain separate explicit actions.
