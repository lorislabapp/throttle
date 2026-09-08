import Foundation

extension EdgeAgentService {

    /// A self-contained `#!/usr/bin/env bash` script: installs Node + tmux + ttyd,
    /// writes the agent (embedded here as base64 so the script needs nothing from the
    /// repo), installs a systemd unit carrying the bearer token via an
    /// EnvironmentFile, and starts it. The user runs this — the app never SSHes.
    public static func deployScript(target: SSHTarget, token: String, httpPort: Int,
                                     ttydPort: Int = 8788, agentSource: String) -> String {
        let keyOpt = target.keyPath.map { " -i \($0)" } ?? ""
        let ssh = "ssh\(keyOpt) -o BatchMode=yes -p \(target.port) \(target.user)@\(target.host)"
        let agentB64 = Data(agentSource.utf8).base64EncodedString()
        let ttydChecksums = ttydSHA256.map { "\($0.value)  ttyd.\($0.key)" }.sorted().joined(separator: "\n")
        var s = "#!/usr/bin/env bash\nset -euo pipefail\n\n"
        s += "# Deploy the Throttle Edge Agent on \(target.host):\(httpPort) (ttyd on \(ttydPort)).\n"
        s += "# 1) Private Node24 LTS + tmux (apt) + ttyd (pinned 1.7.7 release binary, checksummed before running —\n"
        s += "#    Debian/Ubuntu don't package ttyd at all, verified against a real Debian 12 LXC):\n"
        s += nodeBootstrapCommand(overSSH: ssh)
        s += "\(ssh) 'bash -s' <<'INSTALL_TTYD'\n"
        s += "set -euo pipefail\n"
        s += "command -v ttyd >/dev/null && exit 0\n"
        s += "ARCH=$(uname -m)\n"
        s += "curl -fsSL -o /tmp/ttyd.$ARCH https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.$ARCH\n"
        s += "cat <<'SUMS' > /tmp/ttyd.sha256\n"
        s += ttydChecksums + "\n"
        s += "SUMS\n"
        s += "( cd /tmp && grep \"ttyd.$ARCH\\$\" ttyd.sha256 | sha256sum -c - )\n"
        s += "install -m 755 /tmp/ttyd.$ARCH /usr/local/bin/ttyd\n"
        s += "rm -f /tmp/ttyd.$ARCH /tmp/ttyd.sha256\n"
        s += "INSTALL_TTYD\n\n"
        s += "# 2) claude CLI itself, via Anthropic's native installer — NOT npm: on Debian/Ubuntu\n"
        s += "#    `apt-get install npm` drags in ~590 packages / 174MB (gcc, g++, X11 libs, eslint,\n"
        s += "#    the works, verified against a real Debian 12 LXC) just to run one binary. The\n"
        s += "#    native installer needs no Node/npm at all and stays out of the box's way:\n"
        s += "\(ssh) 'command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash'\n"
        s += "# The installer puts the binary in ~/.local/bin, which its own PATH advice (adding to\n"
        s += "# .bashrc) does NOT reach: the agent spawns claude via `bash -lc`, a login shell, which\n"
        s += "# reads .profile, not .bashrc — verified live (LXC134 needed exactly this fix; without\n"
        s += "# it every spawned session would silently fail with \"claude: command not found\").\n"
        s += "\(ssh) 'bash -s' <<'FIX_PATH'\n"
        s += "grep -q \"local/bin\" ~/.profile 2>/dev/null || cat >> ~/.profile <<'PROFILE'\n"
        s += "\n"
        s += "if [ -d \"$HOME/.local/bin\" ] ; then\n"
        s += "    PATH=\"$HOME/.local/bin:$PATH\"\n"
        s += "fi\n"
        s += "PROFILE\n"
        s += "FIX_PATH\n\n"
        s += "# 3) write the agent (embedded, no repo dependency):\n"
        s += "\(ssh) 'mkdir -p /opt/throttle-agent'\n"
        s += "printf %s \(shq(agentB64)) | \(ssh) 'base64 -d > /opt/throttle-agent/throttle-agent.mjs'\n\n"
        s += "# 4) token via a systemd credential file (not argv or process environment):\n"
        s += "\(ssh) 'umask 077; printf \"%s\\n\" \(shq(token)) > /etc/throttle-agent.token; printf \"THROTTLE_AGENT_PORT=%s\\nTHROTTLE_AGENT_TTYD_PORT=%s\\n\" \(httpPort) \(ttydPort) > /etc/throttle-agent.env'\n\n"
        s += "# 5) systemd unit + start:\n"
        s += "\(ssh) 'cat > /etc/systemd/system/throttle-agent.service' <<'UNIT'\n"
        s += unitText()
        s += "UNIT\n"
        s += "\(ssh) 'systemctl daemon-reload && systemctl enable --now throttle-agent && sleep 3 && systemctl is-active throttle-agent'\n\n"
        s += "# 6) publish the loopback-only agent through tailnet-only HTTPS. This requires\n"
        s += "#    Tailscale on the SAME host and HTTPS enabled for the tailnet. Never use Funnel.\n"
        s += "\(ssh) 'command -v tailscale >/dev/null && tailscale serve --bg --yes --https=\(httpPort) localhost:\(httpPort)'\n"
        s += "# 7) back in Throttle, use this node's full *.ts.net MagicDNS name, click Verify,\n"
        s += "#    then complete Claude authorization in the app. The token is stored in a 0600\n"
        s += "#    purpose-scoped file, never ~/.profile or a process argument.\n"
        s += "# 8) Offload with context — real sessions\n"
        s += "#    (with your Mac's transcript resumed) appear instead of the dummy.\n"
        return s
    }
}
