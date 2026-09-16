import Foundation

extension EdgeAgentService {
    static let claudeCodeVersion = "2.1.267"
    static let claudeCodeExecutable = "/opt/throttle-agent/runtime/claude-\(claudeCodeVersion)"

    /// Installs one reviewed Claude Code release directly from Anthropic's release
    /// service. Both architecture and digest are part of this source revision;
    /// updating the CLI therefore requires a reviewable Throttle change.
    static var claudeInstallationScript: String {
        """
        set -euo pipefail
        case "$(uname -m)" in
          x86_64)
            claude_platform=linux-x64
            claude_sha=0399c793ff571d5946ef923d80b4f330d05ac4b6842a6b0775468f5d389403c0
            ;;
          aarch64|arm64)
            claude_platform=linux-arm64
            claude_sha=226a4e009574044a18bf5495f127806b2a1bfcbf25b3c01608705fafee95fefb
            ;;
          *) echo 'Unsupported Claude Code architecture' >&2; exit 1 ;;
        esac
        install -d -m 755 /opt/throttle-agent/runtime "$HOME/.local/bin"
        claude_target=\(claudeCodeExecutable)
        if ! printf '%s  %s\\n' "$claude_sha" "$claude_target" | sha256sum -c - >/dev/null 2>&1; then
          claude_stage=$(mktemp -d /opt/throttle-agent/runtime/.claude.XXXXXXXX)
          trap 'rm -rf "$claude_stage"' EXIT
          curl --fail --location --max-time 180 \\
            "https://downloads.claude.ai/claude-code-releases/\(claudeCodeVersion)/$claude_platform/claude" \\
            -o "$claude_stage/claude"
          printf '%s  %s\\n' "$claude_sha" "$claude_stage/claude" | sha256sum -c -
          chmod 755 "$claude_stage/claude"
          test "$(env -i HOME="$HOME" PATH=/usr/bin:/bin "$claude_stage/claude" --version | awk '{print $1}')" = \
            \(claudeCodeVersion)
          mv -f "$claude_stage/claude" "$claude_target"
          rm -rf "$claude_stage"
          trap - EXIT
        fi
        printf '%s  %s\\n' "$claude_sha" "$claude_target" > "$claude_target.sha256"
        claude_link="$HOME/.local/bin/.claude.$$"
        trap 'rm -f "$claude_link"' EXIT
        ln -s "$claude_target" "$claude_link"
        mv -f "$claude_link" "$HOME/.local/bin/claude"
        """
    }

    static var claudeDeployStepScript: String {
        """
        set -euo pipefail
        \(claudeInstallationScript)
        grep -q "local/bin" ~/.profile 2>/dev/null || \\
          printf '\\nif [ -d "$HOME/.local/bin" ] ; then\\n    PATH="$HOME/.local/bin:$PATH"\\nfi\\n' >> ~/.profile
        """
    }

    static func claudeBootstrapCommand(overSSH ssh: String) -> String {
        """
        # 2) Claude Code \(claudeCodeVersion), pinned by platform and SHA-256:
        \(ssh) 'bash -s' <<'INSTALL_CLAUDE'
        \(claudeInstallationScript)
        INSTALL_CLAUDE
        # The agent launches through a login shell, which reads .profile.
        \(ssh) 'bash -s' <<'FIX_PATH'
        grep -q "local/bin" ~/.profile 2>/dev/null || cat >> ~/.profile <<'PROFILE'

        if [ -d "$HOME/.local/bin" ] ; then
            PATH="$HOME/.local/bin:$PATH"
        fi
        PROFILE
        FIX_PATH

        """
    }
}
