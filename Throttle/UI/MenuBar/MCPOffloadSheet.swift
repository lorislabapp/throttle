import AppKit
import SwiftUI

/// "Run MCP on your server" — guided generator + verifier. Throttle orchestrates;
/// the user owns the box. It builds the exact deploy script (Supergateway
/// `--stateful` unit + copy/npm for repo servers) and the rewire commands, and
/// verifies the endpoint over Streamable HTTP (initialize → tools/list) before
/// you flip `~/.claude.json`. Running the script + the rewire stay the user's
/// step (SSH exec / config edit are outside the app's safe surface).
struct MCPOffloadSheet: View {
    let entry: MCPConfigService.Entry
    var onClose: () -> Void = {}

    @State private var host = ""
    @State private var user = "root"
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var port = 8105
    @State private var verifying = false
    @State private var verifyText: String?
    @State private var verifyOK = false

    private var stdioCommand: String {
        guard let obj = try? JSONSerialization.jsonObject(with: entry.rawData) as? [String: Any],
              let cmd = obj["command"] as? String else { return "" }
        let args = (obj["args"] as? [String]) ?? []
        return ([cmd] + args).joined(separator: " ")
    }
    /// A server whose launch references a local absolute path needs its code copied
    /// to the host first (npx packages don't).
    private var needsCodeCopy: Bool {
        stdioCommand.contains("/Users/") || stdioCommand.contains("/GitHub/")
    }
    private var url: String { MCPOffloadService.remoteURL(host: host.isEmpty ? "<host>" : host, port: port) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run “\(entry.name)” on your server").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { onClose() }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Throttle generates the deploy script + rewire and verifies the endpoint. You run the script on your box (SSH) and apply the rewire — the app never SSHes or edits ~/.claude.json for you.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        field("Host (LAN/Tailscale)", $host, "10.9.8.131")
                        field("Port", Binding(get: { String(port) }, set: { port = Int($0) ?? port }), "8105").frame(width: 90)
                    }
                    HStack(spacing: 10) {
                        field("SSH user", $user, "root")
                        field("SSH key", $keyPath, "~/.ssh/id_ed25519")
                    }

                    label("Deploy script (run on your Mac — it drives the host)")
                    codeBox(deployScript)

                    label("Rewire (run after the script + verify pass)")
                    codeBox(MCPOffloadService.rewireCommands(name: entry.name, url: url).joined(separator: "\n"))

                    HStack(spacing: 10) {
                        Button {
                            verifying = true; verifyText = nil
                            Task {
                                let r = await MCPOffloadService.verify(urlString: MCPOffloadService.remoteURL(host: host, port: port))
                                verifying = false; verifyOK = r.ok; verifyText = r.detail
                            }
                        } label: { Label("Verify endpoint", systemImage: "checkmark.seal") }
                        .disabled(host.isEmpty || verifying)
                        if verifying { ProgressView().controlSize(.small) }
                        if let verifyText {
                            HStack(spacing: 5) {
                                Circle().fill(verifyOK ? .green : .orange).frame(width: 8, height: 8)
                                Text(verifyText).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
    }

    private var deployScript: String {
        let unit = MCPOffloadService.GatewayUnit(
            name: entry.name, httpPort: port,
            workingDir: needsCodeCopy ? "/opt/\(entry.name)" : "/root",
            stdioCommand: needsCodeCopy ? localizedStdio : stdioCommand,
            envFile: nil)
        let key = keyPath.isEmpty ? "" : "-i \(keyPath) "
        let pve = "ssh \(key)-o BatchMode=yes \(user)@\(host.isEmpty ? "<host>" : host)"
        var s = "#!/usr/bin/env bash\nset -euo pipefail\n\n"
        s += "# Deploy \(entry.name) as a Streamable-HTTP MCP on \(host.isEmpty ? "<host>" : host):\(port)\n"
        s += "# 1) ensure Node + Supergateway on the host (once):\n"
        s += "\(pve) 'command -v supergateway >/dev/null || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs && npm i -g supergateway pino-pretty)'\n\n"
        if needsCodeCopy {
            let localDir = (stdioCommand.components(separatedBy: " ").first(where: { $0.contains("/") }).map { ($0 as NSString).deletingLastPathComponent }) ?? "<repo>"
            s += "# 2) copy your LOCAL code (private repo — no clone) + install:\n"
            s += "tar czf - -C \"$(dirname \(localDir))\" \"$(basename \(localDir))\" --exclude node_modules --exclude .git | \(pve) 'mkdir -p /opt && tar xzf - -C /opt && mv /opt/$(basename \(localDir)) /opt/\(entry.name) 2>/dev/null; cd /opt/\(entry.name) && rm -rf node_modules && npm install'\n"
            s += "#    ⚠️ place any secrets/config the server needs on the host (env file or ~/.config/...).\n\n"
        }
        s += "# 3) install the systemd unit + start:\n"
        s += "\(pve) \"bash -c 'cat > /etc/systemd/system/\(unit.serviceName).service'\" <<'UNIT'\n\(unit.unitText)\nUNIT\n"
        s += "\(pve) 'systemctl daemon-reload && systemctl enable --now \(unit.serviceName) && sleep 8 && systemctl is-active \(unit.serviceName)'\n\n"
        s += "# 4) back in Throttle: click Verify endpoint. If it passes, run the rewire below.\n"
        return s
    }
    /// For a copied repo the working dir is /opt/<name>, so strip the local path.
    private var localizedStdio: String {
        let parts = stdioCommand.components(separatedBy: " ")
        return parts.map { $0.contains("/") ? (($0 as NSString).lastPathComponent) : $0 }.joined(separator: " ")
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }
    private func field(_ l: String, _ b: Binding<String>, _ ph: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            TextField(ph, text: b).textFieldStyle(.roundedBorder)
        }
    }
    private func codeBox(_ text: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy").font(.system(size: 11))
            }
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 150)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
