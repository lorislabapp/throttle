# macOS 27 CFO atomic-write correction

Date: 2026-08-02

## Failure

The physical Goliath control-plane gate and Throttle's own
`GoliathControlPlaneTests` reproducibly failed on macOS 27 beta with
`NSCocoaErrorDomain Code=513` / `EPERM`. A standalone Swift probe isolated the
cause:

- `Data.write(options: [.atomic])` succeeded in a new temporary directory;
- `Data.write(options: [.atomic, .completeFileProtection])` failed while
  Foundation created the atomic temporary file.

Apple documents `completeFileProtection` as device-unlocked data protection and
documents `EPERM` when a data-protection class denies file access:

- <https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotection>
- <https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox>

## Correction

The durable CFO journal stores validated receipt hashes and aggregate byte/token
counts, not credentials or model content. The write therefore retains atomic
replacement, its exclusive `flock`, a mode-0700 parent and explicit mode-0600
journal/lock files, but no longer requests the incompatible data-protection
class.

Credential material continues to belong in Keychain. If the journal later
contains confidential payloads, encryption and key release must be designed as
a separate native-security capability rather than silently restoring a
lock-state-dependent Foundation option.

## Evidence

- the three focused `GoliathControlPlaneTests` pass;
- the real Rust → Node SuperGateway → Swift Throttle test passes;
- restart idempotency and mode-0600 assertions remain unchanged.

The exact Super-Orchestrateur master NotebookLM UUID was verified before this
fix. Its settled response returned `GO` with no P0/P1 concern, but supplied no
primary citations; the decision above relies on the physical A/B probe and
Apple documentation.

The guarded post-fix review returned `pass` with no remaining P0/P1 in this
correction. It again supplied no usable primary citation, so it records doctrine
alignment rather than technical proof.
