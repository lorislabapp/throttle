import SwiftUI
import ThrottleShared

/// The home screen: the binding-window hero ring, the 5h/7d windows, weekly
/// cost/tokens/savings, and a freshness line. Renders from the last synced
/// snapshot even when the Mac is offline.
struct LiveUsageView: View {
    @State private var store = MirrorStore.shared
    @State private var subscriber = CloudKitSubscriber.shared
    @State private var now = Date()
    @State private var loading = true
    @State private var showSettings = false
    // 30s tick is plenty for a minute-granularity countdown; gated on .active so it
    // doesn't spin in the background.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let snap = store.latest {
                    content(snap)
                } else if loading && store.lastError == nil {
                    ProgressView("Syncing…").frame(maxHeight: .infinity)
                } else if subscriber.account == .signedOut {
                    ContentUnavailableView("Sign in to iCloud",
                        systemImage: "icloud.slash",
                        description: Text("Use the same Apple Account as your Mac to receive the usage mirror."))
                } else {
                    EmptyMirrorView(error: store.lastError)
                }
            }
            .navigationTitle("Throttle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { _ = await CloudKitSubscriber.shared.fetchLatest(); loading = false }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .onReceive(tick) { now = $0 }
        .task {
            // First render finishes the loading state after the initial fetch lands
            // (or fails), so cold launch shows a spinner rather than "No data yet".
            _ = await CloudKitSubscriber.shared.fetchLatest()
            loading = false
        }
    }

    private func content(_ snap: ThrottleMirrorSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                MeterView(window: snap.bindingWindow, label: "used", now: now)
                    .padding(.top, 12)

                VStack(spacing: 18) {
                    WindowBar(window: snap.fiveHour, label: "5-hour session", now: now)
                    WindowBar(window: snap.sevenDay, label: "7-day", now: now)
                }
                .padding(.horizontal)

                weeklyStats(snap)

                freshness(snap)
            }
            .padding(.bottom, 24)
        }
    }

    private func weeklyStats(_ snap: ThrottleMirrorSnapshot) -> some View {
        HStack(spacing: 12) {
            StatCell(title: "Cost (7d)", value: String(format: "€%.2f", snap.weeklyCostEUR))
            StatCell(title: "Tokens (7d)", value: MirrorUI.compactTokens(snap.weeklyTokens))
            StatCell(title: "Saved", value: MirrorUI.compactTokens(snap.savedTokensThisWeek))
        }
        .padding(.horizontal)
    }

    private func freshness(_ snap: ThrottleMirrorSnapshot) -> some View {
        VStack(spacing: 6) {
            sourceBadge
            Text("\(snap.deviceName) · updated \(MirrorUI.ago(snap.publishedAt, now: now))")
                .font(.caption).foregroundStyle(.secondary)
            if let err = store.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    /// Which transport delivered the current data — the LAN peer link (sub-second,
    /// same Wi-Fi) or the iCloud fallback. Reassures the user sync is live.
    private var sourceBadge: some View {
        let lan = PeerClient.shared.hasLink
        return Label(lan ? "LAN · live" : "iCloud",
                     systemImage: lan ? "wifi" : "icloud.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(lan ? MirrorUI.ok : MirrorUI.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((lan ? MirrorUI.ok : MirrorUI.accent).opacity(0.12), in: Capsule())
            .accessibilityLabel(lan ? "Syncing over local network" : "Syncing over iCloud")
    }
}

struct StatCell: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct EmptyMirrorView: View {
    let error: String?
    var body: some View {
        ContentUnavailableView {
            Label("No data yet", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text(error ?? "Open Throttle on your Mac and enable the iOS mirror in Settings to start syncing.")
        }
    }
}
