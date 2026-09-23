# Edge runtime supply-chain contract

Updated: 2026-09-15

Throttle's generated Edge deployment installs only source-pinned runtime
artifacts. It never pipes a downloaded installer into a shell.

| Component | Pinned revision | Verification before replacement |
|---|---|---|
| Node.js | 24.20.0 | SHA-256 selected for Linux x64 or arm64 |
| ttyd | 1.7.7 | SHA-256 selected for the detected architecture |
| Claude Code | 2.1.267 | SHA-256 selected for Linux x64 or arm64 |

Claude Code 2.1.267 was the `stable` release reported by Anthropic on
2026-09-15. Its exact manifest is
`https://downloads.claude.ai/claude-code-releases/2.1.267/manifest.json`.
The source constants match the manifest's `linux-x64` and `linux-arm64`
checksums. Anthropic documents the native installer and its version targets in
[Set up Claude Code](https://docs.anthropic.com/en/docs/claude-code/getting-started).

## Installation invariant

1. Detect one supported architecture or refuse.
2. Reuse an existing exact-version binary only when its pinned digest matches.
3. Otherwise download to a private staging directory with a finite timeout.
4. Check SHA-256 and the binary-reported version before replacement.
5. Rename the verified binary into place and atomically switch the private
   `~/.local/bin/claude` link.
6. Store the expected digest beside the binary and disable Claude Code's
   automatic updater in the systemd service.

A bad download cannot replace the last verified runtime. Generated deployment
scripts are syntax-tested, and fixtures exercise both rejection and idempotent
reuse.

## Update procedure

Updating any pinned component is a source change. The reviewer must fetch the
exact vendor manifest over HTTPS, compare both supported-platform digests,
update the version and hashes together, rerun the Edge deployment tests, then
qualify the generated script on a disposable Debian/Ubuntu host. A live Edge
installation remains a separate user-authorized effect.

SHA-256 binds the installed bytes to this reviewed source revision. It does not
protect against a vendor origin that served both a malicious artifact and a
malicious manifest. A vendor signature or transparency-backed update framework
would be required to close that upstream trust boundary.
