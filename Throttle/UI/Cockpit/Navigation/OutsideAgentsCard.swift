import AppKit
import SwiftUI

/// Sessions outside Throttle’s tabs. Cloud rows remain a forward-compatible
/// fallback until the CLI actually exposes them.
struct OutsideAgentsCard: View {
    let knownSessionIDs: Set<String>
    var loadSessions: () async -> [ClaudeAgentInventory.Session] = { await ClaudeAgentInventory.load() }
    var refreshInterval: Duration = .seconds(4)
    let onOpen: (ClaudeAgentInventory.Session) -> Void
    @State private var sessions: [ClaudeAgentInventory.Session] = []

    var body: some View {
        let outside = sessions.filter { $0.isBackgroundOrCloud && !knownSessionIDs.contains($0.sessionID ?? "") }
        // This container exists even when the first inventory is empty.
        VStack(spacing: 0) {
            if !outside.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Agents outside Throttle").font(.system(size: 13, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(outside.count)").font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    Divider()
                    ForEach(outside.sorted(by: Self.newestFirst)) { session in
                        row(session)
                        Divider()
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
            }
        }
        .task {
            while !Task.isCancelled {
                let latest = await loadSessions()
                guard !Task.isCancelled else { return }
                sessions = latest
                do { try await Task.sleep(for: refreshInterval) } catch { return }
            }
        }
    }

    private static func newestFirst(_ lhs: ClaudeAgentInventory.Session,
                                    _ rhs: ClaudeAgentInventory.Session) -> Bool {
        (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast)
    }

    private func row(_ session: ClaudeAgentInventory.Session) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.kind == "cloud" ? "cloud" : "terminal")
                .foregroundStyle(session.needsAttention ? Color.orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.name ?? session.id).font(.system(size: 13)).lineLimit(1)
                Text(verbatim: Self.context(session)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if session.kind == "cloud" {
                TaskSpendLabel(entry: nil)
                    .help(Text("Cloud thread usage is not available from this inventory."))
            }
            Button("Open") { onOpen(session) }.controlSize(.small)
                .disabled(Self.safeIdentifier(session.id) == nil)
                .accessibilityIdentifier("outside-agent-open-\(session.id)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Opens it in a Cockpit tab by attaching to the session Claude Code holds,
    /// rather than starting a second agent on the same work.
    static func open(_ session: ClaudeAgentInventory.Session, in cockpit: MultiCockpitModel) {
        let directory = session.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let identifier = Self.safeIdentifier(session.id) else { return }
        cockpit.newSession(
            projectName: session.name ?? session.id,
            cwd: directory,
            runtime: .terminal,
            initialPrompt: "claude attach \(identifier)"
        )
        cockpit.destination = .sessions
    }

    /// Only the CLI's own id shape reaches a shell line.
    nonisolated static func safeIdentifier(_ id: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }

    static func context(_ session: ClaudeAgentInventory.Session) -> String {
        let folder = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
        let state = session.state.map { stateWord($0) } ?? String(localized: "running")
        return "\(kindWord(session.kind)) · \(state) · \(folder)"
    }

    static func kindWord(_ kind: String) -> String {
        switch kind {
        case "background": String(localized: "agents.kind.background", defaultValue: "Background")
        case "cloud": String(localized: "agents.kind.cloud", defaultValue: "Cloud")
        default: kind
        }
    }

    static func stateWord(_ state: String) -> String {
        switch state {
        case "blocked": String(localized: "agents.state.blocked", defaultValue: "waiting on you")
        case "failed": String(localized: "agents.state.failed", defaultValue: "failed")
        case "stopped": String(localized: "agents.state.stopped", defaultValue: "stopped")
        case "running", "working": String(localized: "agents.state.running", defaultValue: "running")
        default: state
        }
    }
}
