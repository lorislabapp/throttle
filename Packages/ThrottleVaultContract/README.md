# ThrottleVaultContract

The client-facing contract of Throttle's Research Vault: the sealed receipt
format and its validator, every request/response type exchanged with the vault
service, the wire limits, and the non-secret service identity a client must pin.
It imports only Foundation and CryptoKit and has no package dependencies. No
storage, key derivation, Keychain, gateway, ingestion, transport or service
runtime code is present.

```swift
import ThrottleVaultContract

let request = try ResearchVaultSearchRequest(query: "cache break-even", limit: 4).validated()
let bundle = try JSONDecoder().decode(ResearchVaultContextBundle.self, from: reply)
```

## Contents

- Receipt format: `ResearchReceipt`, `ResearchFinding`, `ResearchSource`,
  `ResearchSourceKind`, `ResearchEvidenceStatus`, `ResearchSensitivity`,
  `ResearchReceiptValidator` and `ResearchReceiptValidationError`. Sealing
  hashes a canonical JSON payload; validation re-derives it in constant time.
- Query surface: `ResearchVaultSearchRequest`, `ResearchVaultContextBundle`,
  `ResearchVaultContextItem`, `ResearchVaultCitation`,
  `ResearchVaultReceiptProvenance`, `ResearchVaultHealthResponse`,
  `ResearchVaultIPCErrorPayload` and `encodedForIPC()`.
- Owner surface: project admission, receipt import/export, quarantine listing,
  review, reasoning promotion/refresh and reasoning queries with their
  responses. Every request validates itself; every response carries
  `contractVersion`.
- Limits: `ResearchVaultIPCContract` (contract version 1, query bytes, request
  and response byte ceilings, batch sizes, reasoning bounds).
- Identity: `ResearchVaultServiceContract` mach service names, signing
  identifier and team, plus `ResearchVaultCodeIdentity`, which builds the
  Apple code requirement text a client pins before trusting the service.

The wire codec is JSON with sorted keys, unescaped slashes and millisecond
dates. Callers may narrow a query to project keys; no request can carry a
path, key, grant or sensitivity ceiling. Authorization is fixed per
authenticated endpoint on the service side.

## Product modules

`ResearchVaultModel` and `ResearchVaultIPCModel` in `Packages/ResearchVaultKit`
re-export this package, so existing imports compile unchanged. The product
keeps the storage review state, the immutable endpoint grant
(`VaultAuthorization`), the NSXPC protocols, endpoint policies, code
requirement compilation, the connection factory, the `ResearchVaultClient`
actor and the Inbox batch reader. Those form the transport and SDK layer,
which is a separate extraction.

## Validation and status

```sh
swift test --package-path Packages/ThrottleVaultContract --jobs 1
```

`Tests/.../Fixtures/pre-extraction-wire.json` was produced by the original
product modules before extraction from synthetic samples of every type. Tests
reproduce every sample, the contract constants, service names, the code
requirement text and the sealed receipt hash, round-trip each sample through
the codec, reject out-of-contract input and tampered receipts, and check that
no sample carries storage, key or grant fields. Fixtures contain no real data.

Local extraction only. Rights review, distribution notices, version pinning and
remote repository separation remain pending. No new licence grant or
modification of existing rights is made here. See `docs/ip/component-split.md`
in the product.
