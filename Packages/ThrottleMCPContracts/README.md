# ThrottleMCPContracts

Foundation-only declarations for Throttle's eight plan and project-knowledge MCP
tools. No package dependencies, handlers, storage, network, authority grants or
credentials. This is a local extraction candidate, not the complete Throttle
MCP server or a published SDK.

```swift
import Foundation
import ThrottleMCPContracts

let tools = ThrottleMCPSchemas.all
let json = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
```

`all` contains the six `planTools`, followed by bootstrap and project exploration.
Named schema functions are also public. The product decides which tools to
advertise for a project and applies authorization, argument decoding and business
validation. Merely possessing a schema grants no execution capability.

## Compatibility

The JSON names, descriptions, input properties, required fields and ordering are
preserved from the pre-extraction working tree on 2026-09-16. The test fixture
`Tests/ThrottleMCPContractsTests/Fixtures/pre-extraction-tools.json` was captured
from the existing declarations before replacement, including the retry helper,
viability pillar values and project-exploration schema. It contains declarations
only, with no user data or session credentials.

Tests compare the entire JSON structure to that fixed reference. Intentional
future contract changes require explicit compatibility review; do not regenerate
the fixture merely to make a failing comparison pass. These declarations retain
existing behavior: for example, retry fields are individually optional in JSON
Schema, while the handler requires them together when supplied. This extraction
does not add JSON Schema enforcement or claim full MCP specification conformance.

The product's compatibility tests verify its facade, model values and routing.
State-dependent advertisement stays in `PlanMCPTools.advertisedSchemas`.
Additional Throttle tool families are outside this package's scope.

## Validation and distribution

```sh
swift test --package-path Packages/ThrottleMCPContracts --jobs 1
python3 scripts/verify-core-evidence.py --output-parent /private/tmp/throttle-core-evidence
```

The first command also runs from a standalone copy of this package, without the
product repository. The second belongs to the product and tests exact-source
handlers with the contract module. CI runs the standalone tests separately.

Rights qualification, distribution notices, a versioned release and the proposed
repository split remain pending. This extraction makes no new licence grant
and does not change the existing repository licence or previously granted rights.
See `docs/ip/component-split.md` in the product checkout.
