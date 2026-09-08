import Foundation
import ThrottleShared
import WidgetKit

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
    static let historyKey = "ThrottleMirrorHistoryV1"

    private let defaults: UserDefaults
    private let historyEncoder: @Sendable ([ThrottleMirrorSnapshot]) async -> Data?
    private let flushDelayNanoseconds: UInt64
    private let reloadWidgets: @MainActor () -> Void
    private let didIngest: @MainActor (ThrottleMirrorSnapshot) -> Void
    private let didScrub: @MainActor () -> Void
    private var persistenceGeneration: UInt64 = 0

    init(defaults: UserDefaults = CompanionRuntime.defaults,
         historyEncoder: @escaping @Sendable ([ThrottleMirrorSnapshot]) async -> Data? = { snapshots in
             await Task.detached { try? JSONEncoder.iso.encode(snapshots) }.value
         },
         flushDelayNanoseconds: UInt64 = 3_000_000_000,
         reloadWidgets: @escaping @MainActor () -> Void = {
             if !CompanionRuntime.isTesting { WidgetCenter.shared.reloadAllTimelines() }
         },
         didIngest: @escaping @MainActor (ThrottleMirrorSnapshot) -> Void = MirrorStore.updateSurfaces,
         didScrub: @escaping @MainActor () -> Void = MirrorStore.clearSurfaces) {
        self.defaults = defaults
        self.historyEncoder = historyEncoder
        self.flushDelayNanoseconds = flushDelayNanoseconds
        self.reloadWidgets = reloadWidgets
        self.didIngest = didIngest
        self.didScrub = didScrub
        // Persisted cache stays undisclosed until CloudKit proves its owner.
        history = []
        defaults.removeObject(forKey: MirrorWidgetPublication.snapshotKey)
        reloadWidgets()
    }

    func restoreVerifiedCache() {
        guard latest == nil, history.isEmpty else { return }
        history = Array(loadHistory().suffix(Self.historyCap)).map(\.withoutSecrets)
        latest = history.last
        if let data = defaults.data(forKey: MirrorStorage.latestSnapshotKey),
           let saved = try? ThrottleMirrorSnapshot.decoded(from: data),
           latest == nil || saved.publishedAt > (latest?.publishedAt ?? .distantPast) {
            latest = saved.withoutSecrets
            history.append(saved.withoutSecrets)
            history = Array(history.suffix(Self.historyCap))
        }
        if let latest { persistLatest(latest) }
        reloadWidgets()
    }

    /// Accept a freshly fetched snapshot. Ignores stale/duplicate (older or same
    /// publish time), appends to history, updates the widget.
    private(set) var historyFlush: Task<Void, Never>?

    func ingest(_ snap: ThrottleMirrorSnapshot) {
        if let cur = latest, snap.publishedAt <= cur.publishedAt { return }
        latest = snap
        history.append(snap)
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
        persistLatest(snap)          // tiny blob, hot path — the widget needs it now
        scheduleHistoryFlush()       // large array — off-main, debounced
        reloadWidgets()
        didIngest(snap)
    }

    /// Latest snapshot only — a single small blob, cheap enough to write synchronously
    /// so the widget always sees the freshest value.
    private func persistLatest(_ snap: ThrottleMirrorSnapshot) {
        // Credentials are stripped before anything reaches the App Group plist.
        // See `ThrottleMirrorSnapshot.withoutSecrets`: the pairing secret grants
        // keystroke injection into the Mac's terminals, and this container is
        // backed up. The widget needs the numbers, never the secrets.
        if let data = try? snap.withoutSecrets.encoded() {
            defaults.set(data, forKey: MirrorStorage.latestSnapshotKey)
            defaults.set(data, forKey: MirrorWidgetPublication.snapshotKey)
        } else {
            defaults.removeObject(forKey: MirrorWidgetPublication.snapshotKey)
        }
    }

    /// Encoding the whole ≤1500-item history to JSON on every snapshot, on the main
    /// actor, was an O(n) write per network event (the LAN path delivers sub-second).
    /// Debounce to 3s and encode off-main; the on-device charts don't need it instant.
    private func scheduleHistoryFlush() {
        historyFlush?.cancel()
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let snapshot = history.map(\.withoutSecrets)
        let encode = historyEncoder
        let delay = flushDelayNanoseconds
        historyFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            let data = await encode(snapshot)
            guard !Task.isCancelled, let data, let self,
                  self.persistenceGeneration == generation else { return }
            self.defaults.set(data, forKey: Self.historyKey)
        }
    }

    /// Wipe all mirrored data — called when the iCloud identity changes so one
    /// person's usage + 1500-entry history (also read by the widget) never lingers
    /// in the shared App Group for a different iCloud user on the same device.
    func scrub() {
        persistenceGeneration &+= 1
        historyFlush?.cancel()
        historyFlush = nil
        didScrub()
        latest = nil
        history = []
        lastError = nil
        defaults.removeObject(forKey: MirrorStorage.latestSnapshotKey)
        defaults.removeObject(forKey: MirrorWidgetPublication.snapshotKey)
        defaults.removeObject(forKey: Self.historyKey)
        reloadWidgets()
    }

    private static func updateSurfaces(_ snap: ThrottleMirrorSnapshot) {
        ThresholdNotifier.shared.evaluate(snap)
        #if os(iOS)
        ThrottleLiveActivity.sync(snap)
        #endif
    }

    private static func clearSurfaces() {
        PeerClient.shared.stop()
        ThresholdNotifier.shared.scrub()
        #if os(iOS)
        ThrottleLiveActivity.end()
        #endif
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
