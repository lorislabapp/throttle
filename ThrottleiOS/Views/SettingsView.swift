import SwiftUI
import UserNotifications
import ThrottleShared

/// A small Settings surface so notification permission and iCloud state aren't
/// dead-ends: the one-shot onboarding used to be the only place to grant
/// notifications, so a denial (or a later Settings toggle) left the 80/95% alerts
/// silently off with no recovery. Reachable from the Usage tab.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var subscriber = CloudKitSubscriber.shared
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Cap alerts (80% / 95%)", systemImage: "bell.badge")
                        Spacer()
                        notifStateView
                    }
                    if notifStatus == .notDetermined {
                        Button("Enable notifications") {
                            Task { await ThresholdNotifier.shared.requestAuthorization(); await refresh() }
                        }
                    } else if notifStatus == .denied {
                        Button("Open Settings to enable") { openSystemSettings() }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Throttle warns you at 80% and 95% of your binding window, computed on-device from the last synced snapshot — even when the app is closed.")
                }

                Section {
                    HStack {
                        Label("Account", systemImage: "icloud")
                        Spacer()
                        Text(accountText).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("iCloud mirror")
                } footer: {
                    Text(accountFooter)
                }

                Section("Edge sessions") {
                    Label("Configure the agent host + token in the Edge tab.", systemImage: "server.rack")
                        .foregroundStyle(.secondary).font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }
        }
    }

    @ViewBuilder private var notifStateView: some View {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral:
            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(MirrorUI.ok).labelStyle(.iconOnly)
        case .denied:
            Text("Off").foregroundStyle(MirrorUI.warn)
        default:
            Text("Not set").foregroundStyle(.secondary)
        }
    }

    private var accountText: String {
        switch subscriber.account {
        case .available: return "Signed in"
        case .signedOut: return "Signed out"
        case .restricted: return "Restricted"
        case .error: return "Unavailable"
        case .unknown: return "Checking…"
        }
    }
    private var accountFooter: String {
        switch subscriber.account {
        case .signedOut: return "Sign in to iCloud (same Apple Account as your Mac) to receive the mirror."
        case .restricted: return "iCloud is restricted by a profile or Screen Time on this device."
        default: return "The mirror rides on your private iCloud. Nothing is sent to LorisLabs."
        }
    }

    private func refresh() async {
        notifStatus = await ThresholdNotifier.shared.authorizationStatus()
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
