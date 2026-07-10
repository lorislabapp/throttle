import SwiftUI
import ThrottleShared

/// List of the Mac's cockpit sessions/tabs. Tapping a row opens its live terminal
/// and drives it over the paired LAN link (spawned sessions only; the Mac rejects
/// attach otherwise). Off-LAN this stays a read-only mirror.
struct SessionListView: View {
    @State private var store = MirrorStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if let tabs = store.latest?.tabs, !tabs.isEmpty {
                    List(tabs) { tab in
                        NavigationLink {
                            RemoteTerminalScreen(sessionId: tab.id, title: tab.projectName)
                        } label: {
                            SessionRow(tab: tab)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView("No sessions",
                        systemImage: "terminal",
                        description: Text("Cockpit sessions on your Mac will appear here."))
                }
            }
            .navigationTitle("Sessions")
            .refreshable { await CloudKitSubscriber.shared.fetchLatest() }
        }
    }
}

struct SessionRow: View {
    let tab: TabMirror

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: MirrorUI.stateGlyph(tab.stateKind))
                .foregroundStyle(MirrorUI.stateColor(tab.stateKind))
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.projectName).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let model = tab.model {
                        Text(model).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(tab.state).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let eur = tab.eur {
                    Text(String(format: "€%.2f", eur)).font(.subheadline).monospacedDigit()
                }
                if let tokens = tab.tokens {
                    Text(MirrorUI.compactTokens(tokens)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if tab.needsInput {
                Circle().fill(.orange).frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}
