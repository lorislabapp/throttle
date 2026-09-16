# IP inventory gate

Kevin selected the component split on 2026-09-16: open integration interfaces,
separate proprietary product core. See [the recorded decision](decision-brief.md)
and [the proposed component boundary](component-split.md). The product choice
does not mark file-level rights review complete.

Throttle's root MIT licence and its current product/repository description do
not establish a safe public/private boundary on their own. This directory
defines the evidence input for a qualified human and legal decision. It does
not change, narrow or revoke rights already granted.

Generate a factual inventory without assigning rights:

```sh
python3 scripts/ip-inventory.py --output audit-output/ip-inventory.json
```

The report includes every tracked or visible untracked path, its working-file
SHA-256, first and latest Git commits, file kind, pinned dependencies and known
scope contradictions. Every path remains `unreviewed` unless an explicit policy
classifies it.

Copy `ip-policy.example.json` outside the public release line, have the owner
and qualified counsel review every rule, then run:

```sh
python3 scripts/ip-inventory.py \
  --policy /reviewed/path/ip-policy.json \
  --output audit-output/ip-inventory-reviewed.json \
  --require-complete
```

The strict command exits non-zero when any path is unreviewed, two rules
conflict, or the legal review lacks an approved reviewer and decision reference.
The generated inventories belong in `audit-output/` and are not committed by
default. Licence changes, history rewrites, repository moves and public pushes
remain separate human decisions.
