# ThrottlePeerProtocol

Foundation-only framing contract for Throttle's peer link. It has no package
dependencies and includes no networking, pairing, credentials, product model,
or terminal implementation. `ThrottlePeer` retains a public `PeerMessage`
typealias so existing Swift source imports continue to work after rebuilding.
This is source and wire compatibility, not a binary ABI compatibility promise.

## Wire format

One 17-byte header followed by the payload. All integers are unsigned and
big-endian. There is no version or negotiation field in this existing format.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 1 | Kind |
| 1 | 4 | Sender sequence |
| 5 | 8 | Sender timestamp in milliseconds; informational only |
| 13 | 4 | Payload length |
| 17 | length | Opaque payload |

Kinds: `1` hello (UTF-8 name), `2` snapshot (application JSON), `3` heartbeat,
`4` terminal attach (UTF-8 session ID), `5` terminal output, `6` terminal input,
`7` terminal resize (UInt16 columns then UInt16 rows, big-endian), `8` detach.
Heartbeat and detach normally carry an empty payload. This layer decodes
framing only; it does not validate these payload semantics or authorize actions.

`decode(from:)` returns one frame and its consumed byte count, or `nil` for an
incomplete frame. It accepts slices with nonzero indices and trailing frames.
Payload lengths above 4 MiB are rejected as soon as the header is available;
unknown kinds are rejected once the declared frame is complete. The encoder
preserves the existing unchecked behavior: callers must respect the 4 MiB
decoder limit (and the UInt32 representable length). Transport authentication
and buffering limits remain the consumer's responsibility.

## Validation

```sh
swift test --package-path Packages/ThrottlePeerProtocol --jobs 1
swift test --package-path ThrottleShared --jobs 1 --filter 'PeerMessageTests|PeerPairingTests|PredictiveEchoTests|CatchupBufferTests'
```

Conformance tests pin literal wire bytes, kind assignments, integer boundaries,
stream truncation, frame consumption, slice offsets and decoder size limits.
The product's existing peer tests exercise the compatibility alias and terminal
interpretation. CI runs both the standalone conformance and shared package suites.

## Distribution status

Local extraction candidate under the component split in
`docs/ip/component-split.md`; no separate repository or release is created.
The original source provenance comment is retained. Rights qualification and
distribution notices remain pending; this extraction makes no new licence grant
and does not alter the repository's existing licence or previously granted rights.
