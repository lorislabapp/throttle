# Throttle IP boundary decision brief

Status: **option 2 selected by Kevin on 2026-09-16; component and rights review pending**  
Applies to: release work after 3.7.0 (221) source revision

## Recorded product direction

Kevin selected option 2 (component split) in the mission conversation on
2026-09-16. The product strategy is now decided: open integration interfaces,
with a separate proprietary product core. Do not ask for this choice again.

The concrete proposed boundary and migration sequence are in
[component-split.md](component-split.md). This selection records product intent;
it is not an approval of individual file ownership or a change to existing
licences. The reviewed policy remains pending until its evidence is supplied.

This brief makes the remaining decision reviewable. It is not legal advice, a
licence change or evidence that LorisLabs owns every contribution.

## Facts to reconcile

- The repository root contains an MIT licence naming LorisLabs (Christine
  Martin) and contributors. Its text grants broad rights over the software it
  covers.
- The current repository also contains the commercial app, routing logic,
  Research Vault, platform companions and self-hosted Edge surface.
- The README says the repository is not represented as an MIT-only meter. That
  statement does not itself create a path-level licence boundary.
- A future policy cannot be treated as revoking rights already granted for
  earlier public material. Qualified counsel must determine the relevant
  ownership, contribution and release history.
- The factual inventory leaves every path unreviewed until an approved policy
  classifies it. Dependency records and path hashes are evidence inputs, not a
  compatibility opinion.

The current machine-readable inventory is
`audit-output/ip-inventory-20260916.json`. Regenerate it immediately before
review because the path count and digest change with the worktree.

## Options considered (option 2 selected)

The following options were presented; Kevin selected the second:

1. **Whole repository remains MIT.** Align product documentation and commercial
   strategy with the broad rights granted by the current root licence.
2. **Component split.** Keep selected interfaces, SDKs, protocols, schemas,
   adapters, CLI and conformance harnesses in an explicitly public repository;
   move future proprietary implementation, private data and operational defence
   material behind a real package or repository boundary.
3. **Different or dual licensing.** Specify exact components, ownership basis,
   contributor permissions, transition date and downstream terms. This option
   requires direct legal review and cannot be implemented by changing the root
   file alone.

The supplied IP strategy recommends evaluating components separately. Its
default candidate boundary is public integration surfaces and benchmark
methodology, with private routing weights, canonical anti-gaming data, customer
data, differentiated heuristics and operational security intelligence. This is
a recommendation to review, not an approved classification.

## Evidence the reviewer must accept

- exact repository URL, source revision and inventory digest;
- copyright holders and contribution history for every component considered for
  relicensing or dual licensing;
- dependency licence graph, notices, combination/linking model and distributed
  artifacts;
- public release history and the first commit containing each classified path;
- data provenance for fixtures, benchmarks, transcripts and generated assets;
- trademark, contributor agreement and vulnerability-disclosure policy;
- a physical repository/package boundary that matches the legal boundary.

Unknown ownership, provenance, compatibility or data rights stay unknown and
block the affected classification.

## Recorded decision fields

The reviewed policy must identify:

- `reviewer`: qualified person or counsel;
- `decisionRef`: durable memo, ticket or opinion reference;
- decision date and effective source revision;
- exact path rules with `public`, `proprietary` or `excluded` classification;
- rationale for every rule and any path-specific licence expression;
- treatment of earlier public revisions;
- required repository/package migration and notices;
- reconsideration triggers and next review date.

Start from `docs/ip/ip-policy.example.json`, store the reviewed policy outside
the public release line, and run:

```sh
python3 scripts/ip-inventory.py \
  --policy /reviewed/path/ip-policy.json \
  --output audit-output/ip-inventory-reviewed.json \
  --require-complete
```

The release source gate remains blocked unless that command succeeds with zero
unreviewed paths and a current approved legal review. Licence edits, repository
moves, history changes and public pushes remain separate explicit actions.
