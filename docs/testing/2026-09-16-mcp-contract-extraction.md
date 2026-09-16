# MCP contract extraction — local evidence

Date: 2026-09-16. Mission: `8A91A20B-0E22-4C28-B2C7-3A767EF7FFDB`.
Worktree: `build/workflow-contracts-8a91a20b`, branch
`codex/workflow-contracts-8a91a20b`, base
`0f53c96882d8ad4caaf07c27efe0b052421999ef` plus preserved local changes.
Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4.

## Change and compatibility

`Packages/ThrottleMCPContracts` contains Foundation-only declarations for eight
existing tools: plan read/bootstrap, task claim/event/verdict, research record,
viability read and project exploration. It has no package dependencies. Public
schema methods return fresh JSON-compatible dictionaries; `all` exposes the
catalog without querying product state.

`PlanMCPSchemas` and `ProjectKnowledgeMCP.schema` delegate to this canonical
source. The declaration-only retry helper moves into the package; retry decoding,
authorization, storage, handlers and state-dependent advertisement remain in the
product. `project.yml` links the package to the macOS app, and exposes it to its
tests without linking a second copy. XcodeGen regenerated the local project.

Before editing, the existing declarations, retry helper, product viability enum
and exploration declaration were used to capture a JSON baseline. Source hashes
and the capture harness are in `/private/tmp/throttle-mcp-baseline-20260916/`.
The fixed fixture is
`Packages/ThrottleMCPContracts/Tests/ThrottleMCPContractsTests/Fixtures/pre-extraction-tools.json`.
SHA-256: `6a8a11fa8aeb0b7284f85becab02ac17625bc36489650e68255920e35f01c786`.
It matches the captured bytes. Tests compare canonical JSON, preserving every
schema property, description and array order while ignoring object key ordering.

The six standalone tests cover this complete reference, catalog identity,
required-field declarations, retry optionality and integer bounds, review
evidence requirements, and protection against consumer dictionary mutation.
Four product tests connect the facade to this source, compare model enums and
check that every catalog entry reaches a product route. Existing authority,
retry, review and task-state tests remain in the core suite.

## Executed checks

| Check | Result | Evidence |
|---|---|---|
| `swift test --package-path Packages/ThrottleMCPContracts --jobs 1` | PASS: 6 tests | `/private/tmp/throttle-mcp-contracts-20260916.log` |
| Isolated copy, `swift test --package-path /private/tmp/throttle-mcp-isolated-20260916-3i5ur3o6 --build-system native --jobs 1` | PASS: 6 tests | `/private/tmp/throttle-mcp-isolated-20260916.log` |
| Exact-source core suite, including product adapters and handlers | PASS: 257 cases, both commands exit 0, no receipt errors | `/private/tmp/throttle-mcp-core-20260916/throttle-core-evidence-uw1zvyaq/receipt.json` |
| Python `test_core_evidence.py` | PASS: 6 tests | Terminal result |
| Python `test_macos_evidence.py` | PASS: 33 tests | Terminal result |
| SwiftLint 0.65.1 strict, no cache, eight affected Swift files | PASS: 0 violations | `/private/tmp/throttle-mcp-lint-20260916.log` |
| `xcodegen generate` | PASS: package dependency and new test included in generated project | `/private/tmp/throttle-mcp-xcodegen-20260916.log` |
| `git diff --check` | PASS | Local diff check |

Core command:

```sh
python3 scripts/verify-core-evidence.py \
  --output-parent /private/tmp/throttle-mcp-core-20260916 \
  --scratch-path /private/tmp/throttle-core-evidence-20260915-1800-final/throttle-core-evidence-mx84pzg_/package/.build
```

The runner hashes the new module sources and product tests, checks completed
native inventories, and detects source changes during execution. The macOS
evidence profile also includes the entire contract package; its regression test
refuses changed or missing contract sources. iOS does not consume this MCP
package. The prior LAN package remains in both platform profiles.

The standalone copy contains six allowlisted files: manifest, README, two source
files, the compatibility test and fixed JSON fixture. Copy hashes are recorded
in `/private/tmp/throttle-mcp-isolation-20260916.json`. It builds outside the
checkout without product dependencies. This is dependency independence, not an
OS-enforced filesystem isolation claim. The native SwiftPM lane emits a build
system deprecation warning; the default build-system standalone lane also passed.

## Remaining scope

The new exact-source core receipt supersedes the prior 253-case core result for
this working snapshot. It is not the full app-hosted Xcode suite. Full-app build,
exact remote CI (including pinned SwiftLint 0.63.2), runtime journeys and release
artifact gates remain open. Project generation alone is not app compilation.

Other MCP families remain outside this package. The next component split is the
read-only mirror contract and its separate provisioning envelope. Rights review,
notices, version pinning and remote migration remain pending. This slice changes
no licence and performs no commit, push, installation or publication.
