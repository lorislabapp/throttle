# Repository migration proposal — for review before any further remote action

Status: **proposal, not executed.** Step 6 of `component-split.md` requires
destinations, visibility, content and history treatment to be proposed before
any remote action. One remote action already happened and is recorded below so
this proposal starts from the real state rather than the planned one.

## What already happened (2026-09-16)

- Kevin chose a new private repository for the proprietary core.
- `lorislabapp/throttle-core` was created **private**, with GitHub Actions
  **disabled** ($0 build rule; private repos bill macOS minutes). Its `main`
  holds the full history of `lorislabapp/throttle` up to 3.7.0 plus the
  product-lab work of 2026-09-15/16. Nothing new became public.
- A Codemagic workflow file (manual-only) was committed there; no build has run.

This corresponds to `throttle-product` in `component-split.md` under another
name. The public side has **not** been touched.

## Proposed destinations

| Repository | Visibility | Content | History | Licence |
|---|---|---|---|---|
| `lorislabapp/throttle-core` | private — exists | the product: apps, orchestration, routing engine, vault engine, Edge runtime, transport, accounts, internal data and evaluations | full, as pushed | proprietary |
| `lorislabapp/throttle-interfaces` | public — **to create** | the five extracted packages and a conformance suite, from a **positive allow-list** of files only | **none**: a fresh initial commit, so no product file ever reaches it by history | per component, see below |
| `lorislabapp/throttle` | public — exists, MIT | the released app history up to 3.7.0 | already public | MIT, unchanged |

What to do with `lorislabapp/throttle` is the decision with the most weight.
Everything pushed there is already public under MIT and stays so; removing or
archiving it does not withdraw those rights. Options, for counsel:
freeze and archive it with a pointer to the two new repositories; keep it as
the public release/issue tracker only; or leave it as is. **No action proposed
until reviewed.**

## Allow-list for `throttle-interfaces`

Exactly these paths, and nothing inferred from a directory:

- `Packages/ThrottleMCPContracts/**` — task and exploration MCP schemas
- `Packages/ThrottlePeerProtocol/**` — LAN message format
- `Packages/ThrottleMirrorContract/**` — read-only mirror format
- `Packages/ThrottleVaultContract/**` — sealed receipt format and validator
- `Packages/ThrottleVaultClient/**` — NSXPC client SDK on the contract only
- a conformance suite, **not yet written**: format, compatibility and
  malformed-message refusal tests only, synthetic fixtures only
- `SECURITY.md`, a new `README.md`, per-package `LICENSE` and a `NOTICE`

Excluded explicitly: `Shared` folders, any fixture of provenance not proven
synthetic, benchmark corpora, routing weights, abuse or security-operations
material, the vault engine, and the app targets.

## Licence per component

The open-source report recommends Apache-2.0 for SDKs, protocol, schemas,
adapters, CLI and harness (patent grant, broad compatibility), and MIT where
compatibility friction appears. The extracted packages derive from files
already published under MIT, so their MIT permissions stand regardless; any
change of licence for new or rewritten files needs the ownership and
contribution review in `decision-brief.md`. **Not decided here.**

## Gaps found while preparing this

1. No extracted package carries a `LICENSE` or `NOTICE` (0 of 5).
2. The conformance suite and the thin CLI with examples do not exist.
3. The public default branch of `lorislabapp/throttle` is **not protected**.
4. The products still depend on the packages by local path; pinning to a
   published version is part of the migration, not yet done.
5. 21 third-party dependency entries await notice and licence review.
6. Governance for the public repository: CLA or DCO, trademark policy for the
   Throttle name, maintainer and disclosure contacts in `SECURITY.md`.

## Order once reviewed

1. Write the conformance suite and give each package its licence and notice.
2. Verify each package builds and tests with no access to the core.
3. Create `throttle-interfaces` from the allow-list as a single initial commit.
4. Pin `throttle-core` to that published revision; rerun its evidence.
5. Decide the fate of `lorislabapp/throttle` with counsel; protect whatever
   public branch remains.
