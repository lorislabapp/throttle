import AppKit
import SwiftUI

/// "Run sessions on your server" — configure a Throttle Edge Agent on a Proxmox LXC,
/// generate its deploy script, verify the endpoint, and control the remote sessions.
/// Sibling of `MCPOffloadSheet`: Throttle orchestrates + verifies; the user runs the
/// SSH deploy. Measure + coarse lifecycle only (start/stop/pause/resume).
struct SessionOffloadSheet: View {
    var onClose: () -> Void = {}

    @Bindable private var svc = RemoteSessionsService.shared
    @State private var user = "root"
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var verifying = false
    @State private var newCwd = ""

    private var target: EdgeAgentService.SSHTarget {
        EdgeAgentService.SSHTarget(host: svc.host, user: user, keyPath: keyPath.isEmpty ? nil : keyPath, port: 22)
    }

    private var deployScript: String {
        let src = EdgeAgentService.bundledAgentSource() ?? "// throttle-agent.mjs missing from bundle"
        return EdgeAgentService.deployScript(target: target, token: svc.token, httpPort: svc.port, agentSource: src)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Run sessions on your server").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close") { onClose() }.controlSize(.small)
            }
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Throttle generates the deploy script and verifies the agent. You run the script on your box (SSH) — the app never SSHes for you. Sessions run on the box; Throttle measures + coarse-controls them (start/stop/pause).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    group("Agent") {
                        field("Host (LAN/Tailscale)", $svc.host, "10.9.8.131")
                        HStack {
                            field("Port", Binding(get: { String(svc.port) }, set: { svc.port = Int($0) ?? 8787 }), "8787")
                            field("SSH user", $user, "root")
                        }
                        field("SSH key", $keyPath, "~/.ssh/id_ed25519")
                        HStack {
                            field("Bearer token", $svc.token, "generate →")
                            Button("Generate") { svc.token = EdgeAgentService.generateToken() }.controlSize(.small)
                        }
                    }

                    group("1 · Deploy script (run on your Mac)") {
                        codeBox(deployScript)
                        HStack {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(deployScript, forType: .string)
                            }.controlSize(.small)
                            Spacer()
                        }
                    }

                    group("2 · Verify") {
                        HStack {
                            Button(verifying ? "Verifying…" : "Verify endpoint") {
                                verifying = true
                                Task { await svc.verify(); verifying = false }
                            }
                            .disabled(verifying || !svc.isConfigured)
                            if let r = svc.lastVerify {
                                Circle().fill(r.ok ? Color.green : Color.orange).frame(width: 9, height: 9)
                                Text(r.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    group("3 · Remote sessions") {
                        HStack {
                            field("New session cwd", $newCwd, "/root/projects/app")
                            Button("Start") {
                                let cwd = newCwd
                                Task { await svc.start(project: nil, cwd: cwd) }
                            }.controlSize(.small).disabled(newCwd.isEmpty || !svc.isConfigured)
                            Button(svc.polling ? "Stop poll" : "Poll") {
                                svc.polling ? svc.stopPolling() : svc.startPolling()
                            }.controlSize(.small)
                        }
                        if svc.sessions.isEmpty {
                            Text("No remote sessions.").font(.system(size: 11)).foregroundStyle(.tertiary)
                        } else {
                            ForEach(svc.sessions) { s in sessionRow(s) }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(16)
        .frame(width: 520, height: 560)
        .onAppear { svc.startPolling() }
        .onDisappear { svc.stopPolling() }
    }

    private func sessionRow(_ s: EdgeAgentService.RemoteSession) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.state == "working" ? Color.green : Color.secondary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.project).font(.system(size: 12, weight: .medium))
                Text([s.model, s.state].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if let t = s.tokens { Text("\(t)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
            Button("Pause") { Task { await svc.act(s.id, "pause") } }.controlSize(.mini)
            Button("Resume") { Task { await svc.act(s.id, "resume") } }.controlSize(.mini)
            Button("Stop") { Task { await svc.act(s.id, "stop") } }.controlSize(.mini)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: bits

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func field(_ label: String, _ text: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 11))
        }
    }

    private func codeBox(_ s: String) -> some View {
        ScrollView(.horizontal) {
            Text(s).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
