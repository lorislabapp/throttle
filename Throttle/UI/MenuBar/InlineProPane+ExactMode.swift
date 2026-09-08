import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineProPane {
    // MARK: Exact mode

    @ViewBuilder
    var exactBlock: some View {
        SettingsGroupHeader(label: "Exact mode", desc: "Pro")
        if !appState.isPro {
            let expired = LicenseService.shared.state == .expired
            VStack(spacing: 6) {
                Text("Read server-true usage")
                    .font(.system(size: 12.5, weight: .medium))
                Text(expired
                     ? String(localized: "Your license lapsed on this Mac. Reactivate it above to turn Exact mode back on.")
                     : String(localized: "Polls claude.ai so figures aren't local estimates."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if expired {
                    SettingsButton(title: "Reactivate", primary: true) { reactivateStoredKey() }
                        .disabled(activating)
                } else {
                    SettingsButton(title: "Buy Pro · €29", primary: true) {
                        if let url = URL(string: "https://lorislab.fr/throttle/buy") { NSWorkspace.openInBackground(url) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(13)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.vertical, 6)
        } else {
            SettingsRow(title: "Read server-true usage",
                        sub: "Polls claude.ai so figures aren't local estimates.") {
                Toggle("", isOn: Binding(
                    get: { appState.exactModeEnabled },
                    set: { on in
                        appState.setExactModeEnabled(on)
                        if on { ExactModeService.shared.start() } else { ExactModeService.shared.stop(); appState.exactSnapshot = nil }
                    }
                )).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            if appState.exactModeEnabled {
                exactSteps
                exactStatus
            }
        }
    }

    var exactSteps: some View {
        VStack(spacing: 0) {
            exactStep(idx: 1, done: signedIn, "Sign in to claude.ai",
                      action: signedIn ? nil : SettingsButton(title: "Sign in") {
                          Task { @MainActor in
                              let ok = await EmbeddedClaudeSession.shared.presentSignIn()
                              if ok { signedIn = true; _ = await ExactModeService.shared.refresh() }
                          }
                      })
            SettingsHair()
            exactStep(idx: 2, done: appState.exactSnapshot != nil, "Test connection",
                      action: SettingsButton(title: testing ? "Testing…" : "Test") { testConnection() })
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    func exactStep(idx: Int, done: Bool, _ title: String, action: SettingsButton?) -> some View {
        HStack(spacing: 11) {
            ZStack {
                if done {
                    Circle().fill(Color.primary)
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                } else {
                    Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1)
                    Text("\(idx)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(title).font(.system(size: 12.5)).foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 8)
            if let action { action }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    var exactStatus: some View {
        if let err = appState.exactModeError {
            statusBanner(ok: false, text: describeExactModeError(err))
        } else if !connectionStatus.isEmpty {
            statusBanner(ok: connectionStatus.hasPrefix("✓"), text: connectionStatus)
        } else if let snap = appState.exactSnapshot {
            statusBanner(ok: true, text: "Working", meta: "last poll \(relative(snap.fetchedAt))")
        }
    }

    func statusBanner(ok: Bool, text: String, meta: String? = nil) -> some View {
        HStack(spacing: 9) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let meta { Text(meta).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }

    func testConnection() {
        testing = true
        connectionStatus = ""
        Task {
            let result = await ExactModeService.shared.refresh()
            await MainActor.run {
                testing = false
                switch result {
                case .success:
                    connectionStatus = String(localized: "✓ Working. Exact numbers now showing in the meter.")
                    signedIn = true
                    if appState.exactModeEnabled { ExactModeService.shared.start() }
                case .failure(let err):
                    signedIn = false
                    connectionStatus = describeExactModeError(err)
                }
            }
        }
    }

    func relative(_ date: Date) -> String {
        let secs = -Int(date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }
}
