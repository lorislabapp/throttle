import Foundation
import WidgetKit
import ThrottleShared

/// The phone's local truth: the latest mirrored snapshot plus an append-only
/// history (the standalone value — charts/trends that work with the Mac OFF).
/// Persists to the App Group so the widget can render the same data.
@MainActor
@Observable
final class MirrorStore {
    static let shared = MirrorStore()

    private(set) var latest: ThrottleMirrorSnapshot?
    private(set) var history: [ThrottleMirrorSnapshot]
    var lastError: String?

    private static let historyCap = 1500
    private static let historyKey = "ThrottleMirrorHistoryV1"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: MirrorStorage.appGroupID) ?? .standard
    }

    private init() {
        history = []
        history = loadHistory()
        latest = history.last
    }

    /// Accept a freshly fetched snapshot. Ignores stale/duplicate (older or same
    /// publish time), appends to history, updates the widget.
    private var historyFlush: Task<Void, Never>?

    func ingest(_ snap: ThrottleMirrorSnapshot) {
        if let cur = latest, snap.publishedAt <= cur.publishedAt { return }
        latest = snap
        history.append(snap)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        persistLatest(snap)          // tiny blob, hot path — the widget needs it now
        scheduleHistoryFlush()       // large array — off-main, debounced
        WidgetCenter.shared.reloadAllTimelines()
        ThresholdNotifier.shared.evaluate(snap)
    }

    /// Latest snapshot only — a single small blob, cheap enough to write synchronously
    /// so the widget always sees the freshest value.
    private func persistLatest(_ snap: ThrottleMirrorSnapshot) {
        if let data = try? snap.encoded() {
            defaults.set(data, forKey: MirrorStorage.latestSnapshotKey)
        }
    }

    /// Encoding the whole ≤1500-item history to JSON on every snapshot, on the main
    /// actor, was an O(n) write per network event (the LAN path delivers sub-second).
    /// Debounce to 3s and encode off-main; the on-device charts don't need it instant.
    private func scheduleHistoryFlush() {
        historyFlush?.cancel()
        let snapshot = history
        historyFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            let data = await Task.detached { try? JSONEncoder.iso.encode(snapshot) }.value
            guard let data, let self else { return }
            self.defaults.set(data, forKey: Self.historyKey)
        }
    }

    /// Wipe all mirrored data — called when the iCloud identity changes so one
    /// person's usage + 1500-entry history (also read by the widget) never lingers
    /// in the shared App Group for a different iCloud user on the same device.
    func scrub() {
        historyFlush?.cancel()
        latest = nil
        history = []
        defaults.removeObject(forKey: MirrorStorage.latestSnapshotKey)
        defaults.removeObject(forKey: Self.historyKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func loadHistory() -> [ThrottleMirrorSnapshot] {
        guard let data = defaults.data(forKey: Self.historyKey),
              let list = try? JSONDecoder.iso.decode([ThrottleMirrorSnapshot].self, from: data)
        else { return [] }
        return list
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
