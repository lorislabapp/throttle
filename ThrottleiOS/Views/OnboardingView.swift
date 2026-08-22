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
                    // "self-hosted controls" was a promise this target cannot
                    // keep: the Edge views are excluded from the App Store build
                    // (App Review 4.2.7 — a LAN companion for the user's Mac, not
                    // an off-LAN thin client). Paired-device control IS delivered,
                    // through the remote terminal on a Mac session, so that half
                    // stays. Promising a capability the binary does not contain is
                    // the kind of thing a reviewer opens the app to check.
                    Text("""
                    A private mirror of your Mac’s live coding-agent usage, synced \
                    through your own iCloud account. Sessions on a paired Mac stay \
                    controllable from here.
                    """)
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
