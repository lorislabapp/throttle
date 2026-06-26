import Foundation

extension Notification.Name {
    /// In-process re-broadcast of a cross-process command (MultiCockpitModel observes).
    static let throttleCommand = Notification.Name("throttle.command")
}

/// The safe, reversible actions an App Intent / Focus Filter can trigger. File-
/// mutating actions (trim/scope/compact) are deliberately NOT here — per doctrine
/// they require an attended confirmation in the cockpit, never fire-and-forget.
enum ThrottleAction: String, Codable, Sendable {
    case pauseAll, resumeAll, quietOn, quietOff
}

struct ThrottleCommand: Codable, Sendable {
    let id: String          // idempotency token — replayed Darwin coalescing can't double-apply
    let action: ThrottleAction
}

/// Cross-process command bus between out-of-process App Intents and the (possibly
/// not-yet-running) menu-bar app. NotebookLM's cutting-edge pattern: the intent
/// appends a command (with an idempotency token) to the App Group, then posts a
/// Darwin notification to wake the live app; the app drains + applies on the main
/// actor. `openAppWhenRun` on the intents covers the cold-start case — the initial
/// drain() in startObserving() picks up anything queued before launch.
enum ThrottleCommandChannel {
    private static let key = "ThrottleCommandQueueV1"
    private static let darwinName = "com.lorislab.throttle.command"
    private static var defaults: UserDefaults { UserDefaults(suiteName: ThrottleAppGroupID) ?? .standard }

    // MARK: - Producer (App Intent side)

    static func enqueue(_ action: ThrottleAction) {
        var queue = readQueue()
        queue.append(ThrottleCommand(id: UUID().uuidString, action: action))
        writeQueue(queue)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName as CFString), nil, nil, true)
    }

    // MARK: - Consumer (running app)

    @MainActor private static var processed: Set<String> = []

    /// Register the Darwin observer + drain anything already queued. Call once at launch.
    @MainActor static func startObserving() {
        let callback: CFNotificationCallback = { _, _, _, _, _ in
            // C trampoline → hop to main and drain. (No captured context allowed here.)
            DispatchQueue.main.async { MainActor.assumeIsolated { ThrottleCommandChannel.drain() } }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil, callback,
            darwinName as CFString, nil, .deliverImmediately)
        drain()
    }

    @MainActor private static func drain() {
        let queue = readQueue()
        guard !queue.isEmpty else { return }
        writeQueue([])
        for cmd in queue where !processed.contains(cmd.id) {
            processed.insert(cmd.id)
            switch cmd.action {
            case .quietOn:  MemoryPressureMonitor.shared.manualQuietOverride = true
            case .quietOff: MemoryPressureMonitor.shared.manualQuietOverride = false
            case .pauseAll, .resumeAll:
                // The cockpit model owns the sessions — re-broadcast in-process.
                NotificationCenter.default.post(name: .throttleCommand, object: nil,
                                                userInfo: ["action": cmd.action.rawValue])
            }
        }
        if processed.count > 256 { processed.removeAll() }   // bounded; ids are one-shot
    }

    // MARK: - App Group queue

    private static func readQueue() -> [ThrottleCommand] {
        guard let data = defaults.data(forKey: key),
              let q = try? JSONDecoder().decode([ThrottleCommand].self, from: data) else { return [] }
        return q
    }
    private static func writeQueue(_ q: [ThrottleCommand]) {
        defaults.set(try? JSONEncoder().encode(q), forKey: key)
    }
}
