# ThrottleMirrorContract

Foundation-only read data for Throttle's mirror: usage windows, session summaries,
publication time and aggregate counters. No package dependencies, networking,
CloudKit, Keychain, connection endpoints or provisioning fields.

```swift
import ThrottleMirrorContract

let read = try MirrorReadSnapshot.decoded(from: data)
let displayJSON = try read.encoded()
```

The contract has eleven top-level JSON keys: `schemaVersion`, `publishedAt`,
`deviceName`, `fiveHour`, `sevenDay`, `sevenDaySonnet`, `weeklyTokens`,
`weeklyCostEUR`, `savedTokensThisWeek`, `sessionCount`, and `tabs`.
`WindowMirror`, `SessionStateMirror` and `TabMirror` preserve their existing
shape. Unknown state labels survive as strings; their typed view is `nil`.
The convenience codec uses ISO-8601 dates. Required malformed/missing fields
still fail decoding; optional missing/null values retain their existing meaning.
Versions remain permissively decoded as before; the current version is 2.

## Product envelope

The product module `ThrottleShared` retains `ThrottleMirrorSnapshot`, which now
composes `readSnapshot: MirrorReadSnapshot` and `provisioning: MirrorProvisioning`.
Its custom codec preserves the existing **flat JSON**, with no nested `readSnapshot`
or `provisioning` keys and no schema bump. Old initializers and readable property
names remain available after recompilation. No binary ABI promise is made.

`MirrorProvisioning` stays in the product and holds `peerPairingSecret`,
`peerFallbackHost`, `edgeHost`, `edgePort`, and `edgeToken`. The public read type
does not store or re-encode these keys when decoding an envelope. Its JSON
contains only declared read fields, including when unknown fields are present.

This is a type/dependency separation, not a new transport or authorization
boundary. The existing encrypted CloudKit envelope and LAN behavior are preserved.
The product's `withoutSecrets` projection retains legacy endpoint metadata but
removes both credentials for disk persistence. `readSnapshot` removes all five
provisioning fields.

Free-form display strings may still contain sensitive content. The sender must
apply its existing outbound policy before export, for example
`snapshot.scrubbedForPublication().readSnapshot`. The read type itself does not
redact text. Outbound policy remains in the product.

## Validation and status

```sh
swift test --package-path Packages/ThrottleMirrorContract --jobs 1
swift test --package-path ThrottleShared --jobs 1
```

Tests pin the read projection of a synthetic payload captured before extraction,
check dropped provisioning, unknown versions/states and malformed inputs. Product
tests pin the complete legacy envelope, nil/null provisioning, disk projection,
outbound scrubbing and encrypted CloudKit record mapping. Mapping tests are local;
they do not contact CloudKit or prove device behavior.

Local extraction only. Rights review, distribution notices, version pinning and
remote repository separation remain pending. No new licence grant or modification
of existing rights is made here. See `docs/ip/component-split.md` in the product.
