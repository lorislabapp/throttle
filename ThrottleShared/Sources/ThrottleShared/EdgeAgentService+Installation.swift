import Foundation

extension EdgeAgentService {

    // MARK: One-click deploy — remote step bodies
    //
    // Each step is a self-contained bash script meant to be piped to
    // `ssh <target> 'bash -s'` STDIN by `EdgeDeployService`. stdin-piping (never
    // pasting into an interactive shell) sidesteps zsh history expansion — a pasted
    // `#!/usr/bin/env` line explodes as `zsh: event not found: /usr/bin/env`, which
    // is exactly how the manual copy-script path failed in the field. All steps are
    // idempotent so "Deploy" doubles as "repair".

    public struct DeployStep {
        public let label: String
        public let script: String
    }

    public static func deploySteps(token: String, httpPort: Int, ttydPort: Int = 8788,
                                   agentSource: String) -> [DeployStep] {
        let agentB64 = Data(agentSource.utf8).base64EncodedString()
        let ttydChecksums = ttydSHA256.map { "\($0.value)  ttyd.\($0.key)" }.sorted().joined(separator: "\n")
        return [
            DeployStep(label: "SSH connection", script: "set -e; echo ok-$(hostname)"),
            DeployStep(label: "Node + tmux + git", script: """
                set -euo pipefail
                \(nodeInstallationScript)
                command -v tmux >/dev/null || (apt-get update -qq && apt-get install -y tmux)
                command -v git >/dev/null || (apt-get update -qq && apt-get install -y git)
                """),
            DeployStep(label: "ttyd 1.7.7 (checksummed)", script: """
                set -euo pipefail
                command -v ttyd >/dev/null && exit 0
                ARCH=$(uname -m)
                curl -fsSL -o /tmp/ttyd.$ARCH https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$ARCH
                cat <<'SUMS' > /tmp/ttyd.sha256
                \(ttydChecksums)
                SUMS
                ( cd /tmp && grep "ttyd.$ARCH$" ttyd.sha256 | sha256sum -c - )
                install -m 755 /tmp/ttyd.$ARCH /usr/local/bin/ttyd
                rm -f /tmp/ttyd.$ARCH /tmp/ttyd.sha256
                """),
            DeployStep(label: "claude CLI", script: """
                set -euo pipefail
                export PATH="$HOME/.local/bin:$PATH"
                command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
                grep -q "local/bin" ~/.profile 2>/dev/null || printf '\\nif [ -d "$HOME/.local/bin" ] ; then\\n    PATH="$HOME/.local/bin:$PATH"\\nfi\\n' >> ~/.profile
                """),
            DeployStep(label: "Agent \(agentVersionHint)", script: """
                set -euo pipefail
                mkdir -p /opt/throttle-agent
                base64 -d > /opt/throttle-agent/throttle-agent.mjs <<'B64'
                \(agentB64)
                B64
                """),
            DeployStep(label: "Token + systemd unit", script: """
                set -euo pipefail
                umask 077
                printf '%s\\n' \(shq(token)) > /etc/throttle-agent.token
                printf 'THROTTLE_AGENT_PORT=%s\\nTHROTTLE_AGENT_TTYD_PORT=%s\\n' \(httpPort) \(ttydPort) > /etc/throttle-agent.env
                cat > /etc/systemd/system/throttle-agent.service <<'UNIT'
                \(unitText())UNIT
                systemctl daemon-reload
                systemctl enable --now throttle-agent
                systemctl restart throttle-agent
                sleep 2
                systemctl is-active throttle-agent
                """),
            DeployStep(label: "Tailnet HTTPS (Tailscale Serve)", script: """
                set -euo pipefail
                command -v tailscale >/dev/null || { echo 'Tailscale is required on the Edge host; refusing insecure exposure' >&2; exit 1; }
                tailscale status >/dev/null
                tailscale serve --bg --yes --https=\(httpPort) localhost:\(httpPort)
                tailscale serve status
                """)
        ]
    }

    /// The bundled agent source (`throttle-agent.mjs` in the app bundle), or nil if
    /// missing (dev builds that didn't copy the resource).
    public static func bundledAgentSource() -> String? {
        guard let url = Bundle.main.url(forResource: "throttle-agent", withExtension: "mjs"),
              let moduleURL = Bundle.main.url(forResource: "transfer-runtime", withExtension: "mjs"),
              let freshURL = Bundle.main.url(forResource: "fresh-runtime", withExtension: "mjs"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let module = try? String(contentsOf: moduleURL, encoding: .utf8),
              let fresh = try? String(contentsOf: freshURL, encoding: .utf8) else { return nil }
        return embeddedAgentSource(source, transferModule: module, freshModule: fresh)
    }

    /// Each module keeps its ESM scope. The fresh module imports the exact same
    /// transfer data URL, so deployment still requires only one source file.
    static func embeddedAgentSource(_ source: String, transferModule: String, freshModule: String) -> String? {
        let transferMarker = "'./transfer-runtime.mjs'"
        let freshMarker = "'./fresh-runtime.mjs'"
        guard source.components(separatedBy: transferMarker).count == 2,
              source.components(separatedBy: freshMarker).count == 2,
              freshModule.components(separatedBy: transferMarker).count == 2 else { return nil }
        let transferURL = "'data:text/javascript;base64,\(Data(transferModule.utf8).base64EncodedString())'"
        let fresh = freshModule.replacingOccurrences(of: transferMarker, with: transferURL)
        let freshURL = "'data:text/javascript;base64,\(Data(fresh.utf8).base64EncodedString())'"
        return source.replacingOccurrences(of: transferMarker, with: transferURL)
            .replacingOccurrences(of: freshMarker, with: freshURL)
    }

    /// A fresh bearer token for a new agent.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    static func unitText() -> String {
        """
        [Unit]
        Description=Throttle Edge Agent
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        EnvironmentFile=/etc/throttle-agent.env
        LoadCredential=agent-token:/etc/throttle-agent.token
        Environment=HOME=/root
        WorkingDirectory=/opt/throttle-agent
        ExecStart=\(nodeExecutable) /opt/throttle-agent/throttle-agent.mjs
        Restart=on-failure
        User=root
        # Only kill the node process on stop/restart — NOT the whole cgroup — so
        # tmux-hosted claude sessions survive an agent restart/upgrade.
        KillMode=process
        UMask=0077
        NoNewPrivileges=true

        [Install]
        WantedBy=multi-user.target

        """
    }

    static func shq(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
