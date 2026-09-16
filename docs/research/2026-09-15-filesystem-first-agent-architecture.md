# Filesystem-first agents for Throttle — bounded adoption

Date: 2026-09-15  
Decision status: local architecture recommendation; no provider or release decision.

## Decision

Throttle should adopt the filesystem-agent pattern for **discovery, context
assembly and verification**, while retaining typed services for mutations,
authority, budgets, release actions and structured aggregation.

The practical split is:

| Need | Primary mechanism | Why |
|---|---|---|
| Discover project knowledge | Read-only files plus bounded rg, find and cat-equivalent operations | Models already navigate repositories well; reads stay observable and incremental. |
| Exact lookup | Text search over canonical files | Exact names, identifiers and quoted values should not depend on embedding similarity. |
| Aggregation and joins | SQLite/SQL over derived indexes | Counting, grouping and relational joins need deterministic structured execution. |
| Verify an answer | Re-open canonical source files and compare exact digests | The index is rebuildable; original bytes remain the evidence. |
| Change state | Existing typed Throttle services | Task transitions, permissions, budgets, Git integration and release actions need validation and idempotency. |
| Run arbitrary commands | Explicit sandbox capability only | Bash is an execution surface, not an implicit permission grant. |

This avoids two bad extremes: a large catalogue of brittle micro-tools that
pre-decides every navigation step, and an unrestricted shell that can mutate
anything the user account can reach.

## Evidence

Vercel reports that its simplified d0 architecture converted a semantic layer
to YAML, Markdown and JSON and let an agent explore it through filesystem tools.
On the five representative queries disclosed in that post, success rose from
80% to 100%; the difficult case fell from 724 seconds and 100 steps to 141
seconds and 19 steps. Vercel also reports about 37% fewer tokens and a 3.5×
average speedup. This is a small vendor benchmark, useful as a design signal
rather than independent proof for Throttle.

Source: [We removed 80% of our agent's tools](https://vercel.com/blog/we-removed-80-percent-of-our-agents-tools).

Vercel’s implementation guidance emphasizes progressive discovery: list the
available corpus, search exact terms, then read only the useful files. This
reduces context loading and makes each read observable.

Source: [How to build agents with filesystems and bash](https://vercel.com/blog/how-to-build-agents-with-filesystems-and-bash).

Vercel’s later GitHub evaluation also documents the boundary of the idea:
shell-only exploration was initially weaker than SQL for structured questions.
The strongest general pattern was hybrid—SQL for exact aggregation, filesystem
inspection for exploration and source verification.

Source: [Testing if “bash is all you need”](https://vercel.com/blog/testing-if-bash-is-all-you-need).

Eve packages each agent with files and an isolated execution environment. The
useful lesson for Throttle is the per-run workspace and observable file access,
not a requirement to adopt Eve or Vercel infrastructure.

Source: [Introducing eve](https://vercel.com/blog/introducing-eve).

## Throttle architecture

### Canonical files

Each project domain should expose a small, documented tree:

    .throttle/
      plan.json
      log/*.ndjson
      state/*.json
      evidence/
      budget/ledger.json
      red-team/campaigns/*.json
      releases/*.ndjson
      knowledge/
        manifest.json
        decisions/*.md
        components/*.yaml
        sources/*.json

The canonical files carry schema versions, stable identifiers, source
provenance, timestamps and content digests. Generated SQLite indexes and vector
indexes are caches; deleting and rebuilding them must not erase the source.

### Read surface

Throttle should expose a minimal read-only explorer with:

- root-bound path resolution;
- no symlink traversal outside the granted roots;
- file type and size limits;
- refusal of credential/state paths and masking of credential-shaped content;
- bounded output and explicit truncation;
- a receipt listing paths read, byte ranges and digests;
- no hidden write or command execution.

The model decides which files to inspect. Throttle decides which roots and
operations are permitted.

### Structured query surface

Use SQLite when the answer requires counts, grouping, sorting or joins. The
database imports only canonical records, records its source-manifest digest and
is discarded when stale. A result that matters to a release or decision should
carry both the SQL receipt and exact source references.

### Mutation surface

Keep existing typed boundaries:

- PlanStore for task transitions;
- BudgetAdmissionStore for reservations and settlement;
- PlanMCPAuthority for scoped, expiring, revocable MCP grants;
- TaskIntegrationService for Git verification and integration;
- release services for signing, notarization and publication gates.

An agent may use files to understand a task. It must still call the validated
service to change authoritative state.

## Evaluation before broader rollout

Build a corpus of at least 30 real Throttle questions covering:

1. exact lookup;
2. multi-file synthesis;
3. structured aggregation;
4. stale or contradictory sources;
5. unanswerable questions;
6. malicious instructions embedded in source files.

Compare the current retrieval path, filesystem-only navigation and the hybrid
filesystem plus SQLite path. Record answer correctness, citation validity,
abstention quality, wall time, steps, tokens and bytes read. Promote only a
statistically credible improvement that stays inside latency and cost budgets.

## Current implementation boundary

This batch implements `throttle_project_explore`: bounded list, exact search and
read operations over one capability-granted project root. The explorer rejects
escaping paths, every symlink component and credential/state paths, masks known
credential shapes before returning text, limits file count, bytes, matches and
output, and returns a receipt containing each inspected path, byte count,
SHA-256, redaction kinds and incomplete-search state.
It does not execute shell commands or mutate the project.

The batch also keeps structured effects outside the explorer. Task state,
budgets, capability revocation and the release ledger use typed services; an
external release effect is recorded as prepared, then started, then separately
observed so a crash cannot relabel uncertainty as success.

This does not replace Research Vault storage, migrate project data or claim
Vercel’s benchmark applies to Throttle. A rebuildable SQLite projection remains
an evaluation candidate for aggregate questions after a Throttle-specific
benchmark demonstrates that it improves correctness or cost.
