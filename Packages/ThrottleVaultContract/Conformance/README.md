# Throttle sealed research receipt — conformance vectors

`receipt-vectors.json` lets another implementation seal and validate Throttle
research receipts without reading Swift.

## Reproducing a content hash

A receipt's `contentHash` is the lowercase hex SHA-256 of its **canonical
payload**. The payload is every receipt field except `contentHash`, encoded as:

- JSON object keys sorted, no insignificant whitespace;
- forward slashes **not** escaped; non-ASCII characters written literally;
- a nil optional field **omitted**, never written as `null`;
- dates as milliseconds since 1970-01-01T00:00:00Z, as a JSON number.

Each `seal_vectors` entry stores the canonical payload as UTF-8 text, so an
implementation can compare its bytes before comparing hashes. The file was
cross-checked outside Swift: Python's `hashlib.sha256` over the stored
canonical text reproduces every stored hash.

**Known portability risk.** Fractional milliseconds are written with the
platform's floating-point formatting, which other languages may not reproduce
byte for byte. The vectors use whole seconds. An implementation that seals new
receipts should do the same until the format adopts a stricter canonical form
(for example RFC 8785) under a new `schema_version`.

## Validation

Each `reject_vectors` entry is a receipt that must be refused with
`expect_error`: an unsupported schema, a receipt id that is not a UUID, a
project key outside `^[a-z0-9][a-z0-9._-]{0,127}$`, a blank required field, a
source hash that is not 64 lowercase hex characters, a verified finding without
evidence, evidence naming an unknown source, and a tampered claim whose hash no
longer matches.

## Changing the contract

The file is generated from the Swift implementation with
`THROTTLE_REGENERATE_VECTORS=1 swift test --filter ReceiptVectorTests`, and is
otherwise the authority: the same test fails if the implementation drifts from
it, and was checked to fail when a stored expectation is altered. A change to
canonicalization is a new `schema_version`, never an edited vector — existing
receipts must keep validating.

All values are synthetic.
