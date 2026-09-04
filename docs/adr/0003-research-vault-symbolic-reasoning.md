# ADR-0003 — Bounded symbolic reasoning for Research Vault

- Status: Accepted; local implementation validated
- Date: 2026-08-29
- Scope: deterministic derivation, provenance and retraction over approved Research Vault facts

## Context

Research Vault can retrieve cited evidence but cannot yet compute or explain
multi-step consequences. The useful part of the referenced LLM-memory approach
is its small positive Datalog kernel: grounded facts, explicit rules, fixed-point
evaluation and proof edges. Shipping its full project would add a Rust runtime,
a second persistence model and an unreviewed policy surface to a security-
sensitive Swift/XPC architecture.

Primary references and oracle inputs:

- [Lemmalog](https://github.com/grahambrooks/lemmalog), pinned test-oracle commit
  `7d6f1541130aba53949a2da90cc3e134cb0aac01`;
- [W3C PROV-DM](https://www.w3.org/TR/prov-dm/) for provenance concepts;
- [Provenance Semirings](https://doi.org/10.1145/1265530.1265535) for alternative
  derivations;
- [DBSP](https://arxiv.org/abs/2203.16684) as a later incremental-maintenance
  reference, not an MVP dependency.

## Decision

1. Implement a native Swift 6 module, `ResearchVaultReasoning`, with no parser,
   executable rule language, network access or third-party runtime dependency.
2. Support positive, range-restricted rules only. Terms are typed constants or
   variables; every head variable must be bound in the body. Negation,
   aggregation and LLM-authored executable rules are outside this decision.
3. Compute a deterministic least fixed point with explicit limits for base
   facts, rules, body size, term arity, matches, derived facts, iterations,
   derivations and proof traversal. Every exhausted limit fails closed.
4. Never join facts from different `projectKey` values. Derived sensitivity is
   the maximum of all premises; evidence and receipt identifiers are unioned.
5. Intersect premise validity intervals. An empty intersection produces no
   derived fact. Stable semantic fact IDs include project, predicate,
   arguments and the exact interval.
6. Retain every distinct derivation as a rule ID plus ordered premise fact IDs.
   `why` returns a bounded proof subgraph and explicitly marks truncation.
7. The first retraction implementation is a full deterministic rebuild from
   retained base facts. Incremental truth maintenance is deferred until a
   benchmark proves it necessary.
8. Treat Lemmalog only as a pinned development oracle. Its outputs may be
   compared with the versioned JSON golden corpus; it is not linked, bundled or
   invoked by Throttle at runtime.
9. Only owner-approved, versioned rules may reach the evaluator. Model-generated
   rule candidates remain quarantined data and require deterministic validation
   plus human promotion through an authenticated owner boundary.
10. Keep reasoning behind the existing Research Vault trust boundary. This
    change does not expose ingestion, rules, facts or proofs over query XPC and
    does not alter ADR-0002 authorization.
11. Pre-register the full-rebuild Release benchmark before measurement: one
    warm-up followed by five samples on an idle supported Apple Silicon host,
    with p95 budgets of 1 s at 1,000 base facts, 5 s at 10,000 and 60 s at
    100,000; peak process RSS must remain below 1.5 GiB. The scenario derives
    one bounded one-hop `impacted` fact per asserted `dependsOn` fact.

## Rejected alternatives

- **Embed the referenced project:** rejected because the runtime, storage and
  release surface exceed the small semantics Throttle needs.
- **Use an LLM as the inference engine:** rejected because output is not a
  deterministic, complete fixed point and cannot provide durable retraction.
- **Parse a text rule language in the MVP:** rejected because it creates an
  avoidable injection and compatibility surface.
- **Start with incremental deletion:** rejected because full rebuild is easier
  to prove correct and gives a baseline for later performance decisions.
- **Collapse alternative proofs into one:** rejected because deleting one
  source must not retract a conclusion that still has independent support.

## Local validation evidence

The local implementation now includes typed facts/rules, fixed-point
evaluation, project isolation, conservative metadata propagation, bounded
proof traversal, alternative derivations and selective full-rebuild
retraction. Reviewed relations survive derived-cache and rule-pack
invalidation in SQLCipher; promotion and queries remain behind the
authenticated owner XPC boundary.

Fresh 2026-08-30 evidence:

1. the pinned Lemmalog differential oracle passed 100,000 generated bounded
   programs, and the integrated 10,000-program gate passes in `verify.sh`;
2. package verification passes in Debug and Release, including 40 XCTest and
   85 Swift Testing cases, migrations, crash recovery, hostile IPC, release
   negative authorization, MCP process and supply-chain checks;
3. the Workbench distinguishes asserted/derived facts and hypotheses, exposes
   bounded `why`, `impacted` and `what changed` views, and requires explicit
   confirmation to retract an asserted reviewed relation;
4. the full macOS app suite passes from
   `/private/tmp/throttle-reasoning-full-tests-20260830.xcresult`: 353 total,
   350 passed, 3 explicit skips and 0 failures;
5. Release full-rebuild p95 is 117.47 ms at 1,000 facts, 1.09 s at 10,000 and
   12.87 s at 100,000, all under the pre-registered budgets. The 100,000-fact
   run peaks at 319,913,984 bytes RSS, below 1.5 GiB, despite a loaded host;
6. the Release app builds, the oracle is absent from its runtime dependency
   graph, the EN/FR catalog compiles, scoped strict lint has zero violations,
   the current-change secret scan is clean and `git diff --check` passes.

Incremental truth maintenance remains deferred because the bounded full
rebuild meets every pre-registered performance budget. The product gateway
retains its conservative 10,000-base-fact operational cap; the 100,000 case is
a scalability proof, not a silent limit increase.

Distribution remains a separate decision. The local bundle has the expected
identifier and Team ID, but this host reports `CSSMERR_TP_NOT_TRUSTED` for its
certificate chain. Installed helper/runtime, human keyboard/VoiceOver
acceptance, notarization, site and production Sparkle/appcast operations are
not established or authorized by this ADR.

## Consequences

Throttle gains a small auditable reasoning kernel without inheriting another
runtime. Its native implementation, SQLCipher durability, XPC boundary and
automated UI projection are locally validated. This is not evidence of an
installed runtime or public release readiness.
