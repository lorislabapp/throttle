# Throttle LAN peer message — conformance vectors

`peer-message-vectors.json` is the contract another implementation is held to.
It is language-neutral on purpose: an Android, Rust or TypeScript peer can run
the same vectors without reading any Swift.

## What an implementation must do

For every entry in `vectors`, by `type`:

| type | the implementation must |
|---|---|
| `frame` | decode `wire_hex` to `expect`, consuming exactly `expect.consumed` bytes; and encode `expect` back to exactly `wire_hex` |
| `frame_generated` | decode `header_hex` followed by `payload_repeat.count` copies of `payload_repeat.byte_hex`, matching `expect` |
| `incomplete` | report that more bytes are needed — this is **not** an error |
| `reject` | fail with `expect.error` carrying `expect.value` |
| `stream` | decode repeatedly, yielding `expect` in order, with no bytes left over |

A runner must fail on a `type` it does not recognise rather than skip it.

## The rules the vectors encode

- A 17-byte big-endian header: `kind` (uint8), `seq` (uint32),
  `timestamp_millis` (uint64), `length` (uint32), then `length` payload bytes.
- Kind values 1–8 are assigned and never reused. Anything else is refused.
- The payload ceiling is 4 MiB, inclusive. A larger length is refused from the
  header alone, before any payload is buffered.
- Length is checked before kind, so an unknown kind whose payload has not fully
  arrived still waits for bytes.
- `seq` and `timestamp_millis` are unsigned and round-trip at their maximums.
- A stream is read one frame at a time; a prefix of a frame is incomplete.

## Changing the format

A change to framing is a new `format_version`, never an edit to an existing
vector to make an implementation pass. The Swift implementation runs every
vector in `Tests/ThrottlePeerProtocolTests/PeerMessageVectorTests.swift`, and
that test was checked to fail when a vector is altered.

The vectors are synthetic: no device name, session, host or key appears in them.
