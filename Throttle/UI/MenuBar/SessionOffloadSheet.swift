import AppKit
import SwiftUI
import ThrottleShared

/// "Run sessions on your server" — configure a Throttle Edge Agent on a Proxmox LXC,
/// deploy it OVER SSH IN ONE CLICK, verify the endpoint, log the box into Claude
/// without ever opening a terminal, and control the remote sessions.
/// Sibling of `MCPOffloadSheet`. Measure + coarse lifecycle (start/stop/pause/resume).
struct SessionOffloadSheet: View {
    var onClose: () -> Void = {}

    @Bindable private var svc = RemoteSessionsService.shared
    @Bindable private var deploy = EdgeDeployService.shared
    @State private var user = "root"
    @State private var keyPath = "~/.ssh/id_ed25519"
    /// When the SSH host is a Proxmox host fronting the agent's container (DNAT
    /// topology), steps run inside via `pct exec`. Persisted — it's part of the
    /// box identity, like host/port.
    @AppStorage("throttleEdgeLxcID") private var lxcID = ""
    @State private var verifying = false
    @State private var newCwd = ""
    @State private var localSessions: [RemoteSessionsService.LocalSession] = []
    @State private var selectedLocalId: String?
    @State private var offloading = false

    // In-app Claude login on the box (agent ≥0.4.0 drives `claude setup-token`
    // through tmux; we surface the URL + take the code — zero terminal).
    @State private var claudeAuth: Bool?          // nil = unknown (old agent / not checked)
    @State private var authURL: String?
    @State private var authCode = ""
    @State private var authBusy = false
    @State private var authError: String?

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
                    Text("One click: Throttle SSHes to your box, installs everything (Node, tmux, ttyd, claude, the agent), and verifies it. Sessions run on the box; Throttle measures + controls them.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    group("Agent") {
                        field("Host (LAN/Tailscale)", $svc.host, "10.9.8.131")
                        HStack {
                            field("Port", Binding(get: { String(svc.port) }, set: { svc.port = Int($0) ?? 8787 }), "8787")
                            field("SSH user", $user, "root")
                        }
                        HStack {
                            field("SSH key", $keyPath, "~/.ssh/id_ed25519")
                            field("Proxmox LXC ID (if host is a PVE node)", $lxcID, "134")
                        }
                        HStack {
                            field("Bearer token", $svc.token, "generate →")
                            Button("Generate") { svc.token = EdgeAgentService.generateToken() }.controlSize(.small)
                        }
                    }

                    group("1 · Deploy (Throttle does it all over SSH)") {
                        HStack {
                            Button(deploy.running ? "Deploying…" : "Deploy / repair agent") {
                                Task {
                                    let ok = await deploy.deploy(target: target, token: svc.token,
                                                                 httpPort: svc.port, lxcID: lxcID)
                                    if ok { await verifyAndCheckAuth() }
                                }
                            }
                            .disabled(deploy.running || svc.host.isEmpty || svc.token.isEmpty)
                            Spacer()
                        }
                        ForEach(deploy.steps) { s in stepRow(s) }
                        if let f = deploy.failureDetail {
                            Text(f).font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange)
                                .lineLimit(6).textSelection(.enabled)
                        }
                        DisclosureGroup("Manual fallback: deploy script") {
                            codeBox(deployScript)
                            Button("Copy script") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(deployScript, forType: .string)
                            }.controlSize(.small)
                        }
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    group("2 · Verify + Claude login") {
                        HStack {
                            Button(verifying ? "Verifying…" : "Verify endpoint") {
                                Task { await verifyAndCheckAuth() }
                            }
                            .disabled(verifying || !svc.isConfigured)
                            if let r = svc.lastVerify {
                                Circle().fill(r.ok ? Color.green : Color.orange).frame(width: 9, height: 9)
                                Text(r.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        claudeAuthRow
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
                        // Context transfer: pick a local session, ship its FULL
                        // transcript, resume it on the box (no context rebuild).
                        HStack {
                            Picker("", selection: $selectedLocalId) {
                                Text("Local session…").tag(String?.none)
                                ForEach(localSessions) { s in
                                    Text("\(s.id.prefix(8)) · \(s.project.split(separator: "-").suffix(2).joined(separator: "-")) · \(s.sizeBytes / 1024) KB")
                                        .tag(String?.some(s.id))
                                }
                            }
                            .labelsHidden().controlSize(.small).frame(maxWidth: 260)
                            Button(offloading ? "Offloading…" : "Offload with context") {
                                guard let s = localSessions.first(where: { $0.id == selectedLocalId }) else { return }
                                let cwd = newCwd
                                offloading = true
                                Task { await svc.offload(s, remoteCwd: cwd); offloading = false }
                            }
                            .controlSize(.small)
                            .disabled(offloading || selectedLocalId == nil || newCwd.isEmpty || !svc.isConfigured)
                        }
                        if let status = svc.offloadStatus {
                            Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
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
        .frame(width: 520, height: 620)
        .onAppear {
            svc.startPolling()
            localSessions = RemoteSessionsService.recentLocalSessions()
            if svc.isConfigured { Task { await verifyAndCheckAuth() } }
        }
        .onDisappear { svc.stopPolling() }
    }

    // MARK: Claude login on the box — fully in-app

    @ViewBuilder private var claudeAuthRow: some View {
        HStack(spacing: 8) {
            switch claudeAuth {
            case .some(true):
                Circle().fill(Color.green).frame(width: 9, height: 9)
                Text("Claude logged in on the box").font(.system(size: 11)).foregroundStyle(.secondary)
            case .some(false):
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                Text("Claude not logged in").font(.system(size: 11)).foregroundStyle(.secondary)
                Button(authBusy ? "Starting…" : "Log in…") { Task { await startAuth() } }
                    .controlSize(.small).disabled(authBusy)
            case .none:
                EmptyView()
            }
        }
        if let url = authURL, claudeAuth == false {
            VStack(alignment: .leading, spacing: 6) {
                Button("1 · Open the authorization page") {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }.controlSize(.small)
                HStack {
                    TextField("2 · Paste the code here", text: $authCode)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("Submit") { Task { await submitAuthCode() } }
                        .controlSize(.small).disabled(authCode.isEmpty || authBusy)
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        if let e = authError {
            Text(e).font(.system(size: 10)).foregroundStyle(.orange)
        }
    }

    private func verifyAndCheckAuth() async {
        verifying = true
        await svc.verify()
        if let h = try? await EdgeAgentService.health(baseURL: svc.baseURL) {
            claudeAuth = h.claudeAuth   // nil on agents <0.4.0 → row hidden
        }
        verifying = false
    }

    private func startAuth() async {
        authBusy = true; authError = nil; authURL = nil
        do {
            try await EdgeAgentService.authStart(baseURL: svc.baseURL, token: svc.token)
            // Poll for the login URL (setup-token takes a moment to print it).
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 700_000_000)
                let p = try await EdgeAgentService.authPeek(baseURL: svc.baseURL, token: svc.token)
                if p.done { claudeAuth = true; break }
                if let u = p.url { authURL = u; break }
            }
            if authURL == nil && claudeAuth != true { authError = "No login URL appeared — check the box." }
        } catch {
            authError = "Login start failed: \(error.localizedDescription)"
        }
        authBusy = false
    }

    private func submitAuthCode() async {
        authBusy = true; authError = nil
        do {
            try await EdgeAgentService.authSubmit(baseURL: svc.baseURL, token: svc.token, code: authCode)
            // Wait for the agent to see the minted token and persist it.
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 800_000_000)
                let p = try await EdgeAgentService.authPeek(baseURL: svc.baseURL, token: svc.token)
                if p.done { claudeAuth = true; authURL = nil; authCode = ""; break }
            }
            if claudeAuth != true { authError = "Code submitted but login not confirmed — try again." }
        } catch {
            authError = "Code submit failed: \(error.localizedDescription)"
        }
        authBusy = false
    }

    private func stepRow(_ s: EdgeDeployService.StepStatus) -> some View {
        HStack(spacing: 6) {
            switch s.state {
            case .pending: Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(.tertiary)
            case .running: ProgressView().controlSize(.mini)
            case .done:    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
            case .failed:  Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text(s.label).font(.system(size: 11))
                .foregroundStyle(s.state == .pending ? .tertiary : .secondary)
            Spacer()
        }
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
