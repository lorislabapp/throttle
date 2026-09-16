# ThrottleVaultClient

Thin macOS client for Throttle's Research Vault service, built only on
`ThrottleVaultContract` (re-exported). It owns the two NSXPC interfaces, the
Apple code-requirement check, the connection factory that pins the service
identity, the secretless one-call `ResearchVaultClient` actor, the
`makeCheatCodeClient()` constructor and the Inbox batch reader. No storage,
key, Keychain, gateway, endpoint grant or service runtime code is present.

```swift
import ThrottleVaultClient

let client = try ResearchVaultServiceContract.makeCheatCodeClient()
let health = try await client.health()
let bundle = try await client.search(query: "cache break-even", limit: 4)
```

## Trust model

Every call opens one connection to a mach service, sets the code-signing
requirement derived from `ResearchVaultCodeIdentity`, sends one JSON request,
bounds the reply to `ResearchVaultIPCContract.maximumResponseBytes`, then
invalidates the connection. Requests are validated by the contract before any
connection exists; a client cannot widen the project scope or sensitivity
ceiling fixed on the service side. Owner operations need an owner endpoint
name, which the CheatCode constructor never provides. A missing service fails
closed with `serviceUnavailable`.

The `@objc` protocols keep their selectors; their Objective-C runtime names
now carry this module's name. NSXPC matches messages by selector against the
receiver's exported interface, and the app and its helper ship together, so no
installed pairing is affected. This is a source/wire compatibility statement
after rebuilding, not a binary ABI promise.

## Product module

`ResearchVaultXPCClient` in `Packages/ResearchVaultKit` re-exports this package
and keeps only the endpoint policies, which carry the immutable service grant.
The XPC service conforms to the interfaces through that re-export.

## Validation and status

```sh
swift test --package-path Packages/ThrottleVaultClient --jobs 1
```

`Tests/.../Fixtures/pre-extraction-xpc-interface.json` records the selectors of
both interfaces and the receipt file suffix as captured from the original
product module. Tests compare them, compile the distribution requirement,
check the factory pins the right interface without activating, and exercise
the client's refusals (owner operations on a query-only client, out-of-contract
requests, unavailable service). No live vault service is contacted.

Local extraction only. Rights review, notices, version pinning and repository
separation remain pending. No new licence grant or modification of existing
rights is made here. See `docs/ip/component-split.md` in the product.
