import AppKit
import Foundation

/// Flags an off-main job loop polls between units of work. The UI sets them;
/// the loop reads them. A lock, not an actor: the indexer is synchronous code
/// on a detached task and must be able to ask "stop?" without awaiting.
final class BackgroundWorkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var skip = false
    private var pause = false

    var isPauseRequested: Bool { lock.withLock { pause } }
    /// True when the loop should leave the current item now (skip or pause).
    var shouldInterrupt: Bool { lock.withLock { skip || pause } }

    func requestSkip() { lock.withLock { skip = true } }
    func requestPause() { lock.withLock { pause = true } }

    /// Clears and returns the skip flag, so one Skip skips exactly one item.
    func consumeSkip() -> Bool {
        lock.withLock {
            defer { skip = false }
            return skip
        }
    }
}

// The value types BackgroundWork publishes, kept apart from its lifecycle code.
extension BackgroundWork {
    enum Kind: String, CaseIterable, Sendable, Identifiable {
        case semanticIndex, vaultIngest
        var id: String { rawValue }

        var title: String {
            switch self {
            case .semanticIndex: String(localized: "Semantic index")
            case .vaultIngest: String(localized: "Research Vault ingest")
            }
        }
        var subtitle: String {
            switch self {
            case .semanticIndex: String(localized: "on-device embeddings")
            case .vaultIngest: String(localized: "trusted folders")
            }
        }
        var unit: String {
            switch self {
            case .semanticIndex: String(localized: "repos")
            case .vaultIngest: String(localized: "files")
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case running
        /// A pause was requested; the job stops after the file it is on.
        case pausing
        case paused
        /// Paused by the kernel's memory-pressure signal; resumes on its own.
        case pressurePaused
        case finished
    }

    struct Failure: Equatable, Sendable {
        var name: String
        var reason: String
        /// What Retry re-runs (a repo root for the index).
        var path: String?
    }

    struct Job: Identifiable, Equatable, Sendable {
        let kind: Kind
        var id: Kind { kind }
        var phase: Phase = .running
        var done = 0
        var total = 0
        /// The vault only learns a folder's size once it scans it, so the total
        /// can still grow while other folders wait. Rendered as "120+".
        var totalIsPartial = false
        var current: String?
        var startedAt = Date()
        var finishedAt: Date?
        var skippedItems = 0
        var failures: [Failure] = []
        /// Items already done before this run started (a resumed pass), so the
        /// ETA is extrapolated from this run's own pace only.
        var baseline = 0

        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
        var isActive: Bool { phase != .finished }

        /// Extrapolated from finished items only, so it never exists before the
        /// first one completes, and never while paused.
        func etaSeconds(now: Date = Date()) -> TimeInterval? {
            guard phase == .running, done > baseline, total > done else { return nil }
            let perItem = now.timeIntervalSince(startedAt) / Double(done - baseline)
            return perItem * Double(total - done)
        }
    }

    /// The glyph the menu bar draws under its gauge. Stored, never computed in
    /// the label: see `MultiCockpitModel.waitingCount` for why.
    enum MenuBarMark: Equatable, Sendable {
        /// Solid hairline; the step is 0...`menuBarSteps`.
        case progress(Int)
        /// Dotted hairline: waiting for memory pressure to clear.
        case quiet
        /// A small warning glyph: an item failed.
        case failed
    }
    static let menuBarSteps = 16

    /// "Background work: indexing 3 of 9 repos, about 4 minutes left."
    func describe() -> String? {
        if waitingForMemory {
            return String(localized: "Background work: skipped, memory pressure. Retries when memory clears.")
        }
        guard let head = headline else { return nil }
        switch head.phase {
        case .finished:
            return hasFailures
                ? String(localized: "Background work: finished, \(head.failures.count) failed.")
                : String(localized: "Background work finished.")
        case .paused, .pausing:
            return String(localized: "Background work: paused at \(head.done) of \(head.total) \(head.kind.unit).")
        case .pressurePaused:
            return String(localized:
                "Background work: paused by memory pressure at \(head.done) of \(head.total) \(head.kind.unit).")
        case .running:
            let verb = head.kind == .semanticIndex ? String(localized: "indexing") : String(localized: "ingesting")
            var line = String(localized: "Background work: \(verb) \(head.done) of \(head.total) \(head.kind.unit)")
            if let eta = head.etaSeconds() { line += String(localized: ", about \(Self.minutes(eta)) left") }
            return line + "."
        }
    }

    /// One VoiceOver announcement per start / finish / skip / fail; progress
    /// ticks never announce.
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    /// "4 min", "1 min" — never "0 min" while something is left.
    static func minutes(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        return String(localized: "\(mins) min")
    }
}

/// Throttle's own process CPU time (user + system), from `getrusage`.
enum ProcessCPU {
    static func sample() -> (wall: TimeInterval, cpu: TimeInterval) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> TimeInterval {
            TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
        }
        return (ProcessInfo.processInfo.systemUptime, seconds(usage.ru_utime) + seconds(usage.ru_stime))
    }
}
