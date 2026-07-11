import SwiftUI
import ThrottleShared

/// Sessions hosted on a Throttle Edge Agent (e.g. an offload LXC) — distinct from
/// `SessionListView`, which mirrors the Mac's own cockpit over CloudKit/LAN. The
/// agent itself is deployed from the Mac (`SessionOffloadSheet`); this view only
/// consumes an already-running agent's token-gated API.
struct EdgeSessionListView: View {
    @State private var svc = EdgeSessionsService.shared
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !svc.isConfigured {
                    ContentUnavailableView {
                        Label("No edge agent configured", systemImage: "server.rack")
                    } description: {
                        Text("Enter the host and token from your Mac's Edge Agent sheet.")
                    } actions: {
                        Button("Configure") { showSettings = true }
                    }
                } else if svc.sessions.isEmpty {
                    ContentUnavailableView("No remote sessions",
                        systemImage: "terminal",
                        description: Text("Start a session from the Mac cockpit to see it here."))
                } else {
                    List(svc.sessions) { s in
                        NavigationLink {
                            EdgeTerminalScreen(session: s)
                        } label: {
                            EdgeSessionRow(session: s)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Edge Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await svc.refresh() }
            .task { svc.startPolling() }
            .onDisappear { svc.stopPolling() }
            .sheet(isPresented: $showSettings) { EdgeAgentSettingsSheet(svc: svc) }
        }
    }
}

private struct EdgeSessionRow: View {
    let session: EdgeAgentService.RemoteSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.state == "idle" ? "moon.zzz" : "bolt.fill")
                .foregroundStyle(session.state == "idle" ? Color.secondary : Color.orange)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let model = session.model {
                        Text(model).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(session.state).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let tokens = session.tokens {
                Text(MirrorUI.compactTokens(tokens)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EdgeAgentSettingsSheet: View {
    @Bindable var svc: EdgeSessionsService
    @Environment(\.dismiss) private var dismiss
    @State private var portText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Host (Tailscale IP or hostname)", text: $svc.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .onChange(of: portText) { _, new in if let p = Int(new) { svc.port = p } }
                    SecureField("Token", text: $svc.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let v = svc.lastVerify {
                    Section("Status") {
                        Label(v.detail, systemImage: v.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(v.ok ? .green : .red)
                    }
                }
            }
            .navigationTitle("Edge Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Verify") { Task { await svc.verify() } }
                }
            }
            .onAppear { portText = String(svc.port) }
        }
    }
}
