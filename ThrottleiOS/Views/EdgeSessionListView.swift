import SwiftUI
import ThrottleShared

/// Sessions hosted on a Throttle Edge Agent (e.g. an offload LXC) — distinct from
/// `SessionListView`, which mirrors the Mac's own cockpit over CloudKit/LAN. The
/// agent itself is deployed from the Mac (`SessionOffloadSheet`); this view only
/// consumes an already-running agent's token-gated API.
struct EdgeSessionListView: View {
    @State private var svc = EdgeSessionsService.shared
    @State private var showSettings = false
    @State private var showNewSession = false

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
                            .buttonStyle(.borderedProminent)
                    }
                } else if svc.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("No remote sessions", systemImage: "terminal")
                    } description: {
                        Text("Start one here, or offload a session from the Mac cockpit.")
                    } actions: {
                        Button("New session") { showNewSession = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if let status = svc.actionStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(svc.sessions) { s in
                            NavigationLink {
                                EdgeTerminalScreen(session: s)
                            } label: {
                                EdgeSessionRow(session: s)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Haptics.tap(.warning)
                                    Task { await svc.act(s.id, "stop") }
                                } label: { Label("Stop", systemImage: "stop.fill") }
                                if s.state == "paused" {
                                    Button {
                                        Haptics.tap(.success)
                                        Task { await svc.act(s.id, "resume") }
                                    } label: { Label("Resume", systemImage: "play.fill") }
                                        .tint(MirrorUI.ok)
                                } else {
                                    Button {
                                        Haptics.tap(.success)
                                        Task { await svc.act(s.id, "pause") }
                                    } label: { Label("Pause", systemImage: "pause.fill") }
                                        .tint(MirrorUI.warn)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Edge Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewSession = true } label: { Image(systemName: "plus") }
                        .disabled(!svc.isConfigured)
                }
            }
            .refreshable { await svc.refresh() }
            .task { svc.startPolling() }
            .onDisappear { svc.stopPolling() }
            .sheet(isPresented: $showSettings) { EdgeAgentSettingsSheet(svc: svc) }
            .sheet(isPresented: $showNewSession) { NewEdgeSessionSheet(svc: svc) }
        }
    }
}

/// Start (or resume) a remote session. The optional resume id is the iOS half of
/// "offload with context" — resume a transcript the box already has (e.g. one the
/// Mac uploaded) rather than starting cold.
private struct NewEdgeSessionSheet: View {
    @Bindable var svc: EdgeSessionsService
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var resumeId = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Working directory (e.g. /root/projects/app)", text: $cwd)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Where")
                } footer: {
                    Text("A path on the box. It's created if it doesn't exist yet.")
                }
                Section {
                    TextField("Session id to resume (optional)", text: $resumeId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Resume with context")
                } footer: {
                    Text("Leave empty for a fresh session. Paste an id already offloaded to the box to resume its full conversation.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Starting…" : "Start") {
                        busy = true
                        let r = resumeId.trimmingCharacters(in: .whitespaces)
                        Task {
                            let ok = await svc.start(cwd: cwd.trimmingCharacters(in: .whitespaces),
                                                     resume: r.isEmpty ? nil : r)
                            busy = false
                            Haptics.tap(ok ? .success : .error)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(busy || cwd.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct EdgeSessionRow: View {
    let session: EdgeAgentService.RemoteSession

    private var working: Bool { session.state == "working" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 28)
                .symbolEffect(.pulse, isActive: working)
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
                Text(MirrorUI.compactTokens(tokens))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.project), \(session.state)")
    }

    private var glyph: String {
        switch session.state {
        case "idle":   return "moon.zzz"
        case "paused": return "pause.circle.fill"
        default:        return "bolt.fill"
        }
    }
    private var tint: Color {
        switch session.state {
        case "idle":   return .secondary
        case "paused": return MirrorUI.warn
        default:        return MirrorUI.ok
        }
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
