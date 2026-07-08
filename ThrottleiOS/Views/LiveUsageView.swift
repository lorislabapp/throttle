import SwiftUI
import ThrottleShared

/// The home screen: the binding-window hero ring, the 5h/7d windows, weekly
/// cost/tokens/savings, and a freshness line. Renders from the last synced
/// snapshot even when the Mac is offline.
struct LiveUsageView: View {
    @State private var store = MirrorStore.shared
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if let snap = store.latest {
                    content(snap)
                } else {
                    EmptyMirrorView(error: store.lastError)
                }
            }
            .navigationTitle("Throttle")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await CloudKitSubscriber.shared.fetchLatest() }
        }
        .onReceive(tick) { now = $0 }
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
        VStack(spacing: 2) {
            Text("\(snap.deviceName) · updated \(MirrorUI.ago(snap.publishedAt, now: now))")
                .font(.caption).foregroundStyle(.secondary)
            if let err = store.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
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
