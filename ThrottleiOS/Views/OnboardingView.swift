import SwiftUI

/// First-run sheet: what the app does, how to turn the mirror on from the Mac,
/// and the notification opt-in. Shown once (persisted flag).
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    static let doneKey = "ThrottleiOSOnboardedV1"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Precise cockpit,\nin your pocket")
                        .font(.largeTitle.weight(.bold))
                    Text("A read-only mirror of your Mac’s live Claude Code usage — synced over your own private iCloud. No server, no VPN.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                step(1, "Same iCloud account",
                     "Sign in to iCloud on this iPhone with the same Apple ID as your Mac. That’s the only requirement.")
                step(2, "Turn on the mirror (Mac)",
                     "In Throttle on your Mac → Settings → “iOS companion mirror (iCloud)”. It publishes your usage to your private iCloud.")
                step(3, "Get notified",
                     "Optional: allow notifications so we can warn you at 80% and 95% — even when the app is closed.")

                Button {
                    Task {
                        await ThresholdNotifier.shared.requestAuthorization()
                        finish()
                    }
                } label: {
                    Text("Allow notifications")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(MirrorUI.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }

                Button("Not now") { finish() }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(MirrorUI.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        dismiss()
    }
}
