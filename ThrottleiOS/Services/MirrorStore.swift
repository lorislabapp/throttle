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
    func ingest(_ snap: ThrottleMirrorSnapshot) {
        if let cur = latest, snap.publishedAt <= cur.publishedAt { return }
        latest = snap
        history.append(snap)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        persist(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persist(_ snap: ThrottleMirrorSnapshot) {
        // Latest snapshot for the widget (single small blob).
        if let data = try? snap.encoded() {
            defaults.set(data, forKey: MirrorStorage.latestSnapshotKey)
        }
        // History (capped) for on-device charts.
        if let data = try? JSONEncoder.iso.encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
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
