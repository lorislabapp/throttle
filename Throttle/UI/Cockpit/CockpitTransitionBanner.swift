import SwiftUI

/// Isolate transient lifecycle observation from the complete cockpit body.
struct CockpitTransitionBanner: View {
    let tab: CockpitTab
    let onForget: () -> Void
    @State private var showRecovery = false

    var body: some View {
        if let issue = tab.stopIssue {
            VStack(alignment: .leading, spacing: 6) {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
                Button("Review recovery…") { showRecovery = true }
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .sheet(isPresented: $showRecovery) { recovery }
        } else if tab.isTransitioning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tab.isStopping ? "Stopping session…" : "Transferring session…")
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .accessibilityElement(children: .combine)
        }
    }

    private var recovery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session recovery").font(.headline)
            Text("""
                Throttle could not confirm the process stop. Review remaining processes in Activity Monitor \
                before continuing this work.
                """)
            Text("""
                You can keep this tab, or forget it after your review. Forgetting does not confirm the process stop \
                or start a replacement. Closing its terminals may end attached processes. \
                Existing native transcripts are not deleted.
                """)
            if let identity = tab.rootProcessIdentity {
                Text("Main shell PID: \(identity.pid)").textSelection(.enabled)
            }
            if let pid = tab.sideShellPIDForRecovery {
                Text("Side shell PID: \(pid)").textSelection(.enabled)
            }
            if let sessionID = tab.sessionId {
                Text("Native session: \(sessionID)").textSelection(.enabled)
            }
            HStack {
                Button("Keep tab") { showRecovery = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Forget tab", role: .destructive) {
                    showRecovery = false
                    onForget()
                }
            }
        }
        .padding(24).frame(width: 440)
    }
}
