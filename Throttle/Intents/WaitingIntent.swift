import AppIntents
import Foundation

/// What waits on the person, frozen for Siri and Shortcuts. The running app
/// writes it whenever sessions or plans change; an intent may run out of
/// process, so it reads this rather than the Cockpit's live model.
enum ThrottleWaitingKind: String, Codable, Sendable { case question, decision, blocked }

/// A project as the waiting summary needs it: its open decisions and blocked count.
struct ThrottleWaitingProject: Sendable {
    let name: String
    let decisions: [String]
    let blocked: Int
}

struct ThrottleWaitingSnapshot: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable {
        let kind: ThrottleWaitingKind
        let title: String
        let context: String
    }

    let items: [Item]
    let computedAt: Date

    static let empty = ThrottleWaitingSnapshot(items: [], computedAt: .distantPast)

    /// Questions first (a session is stuck), then decisions, then blocked work.
    static func make(questions: [(session: String, question: String?)],
                     projects: [ThrottleWaitingProject],
                     now: Date = Date()) -> ThrottleWaitingSnapshot {
        var items = questions.map {
            Item(kind: .question, title: $0.question ?? String(localized: "A session is waiting for you"),
                 context: $0.session)
        }
        for project in projects {
            items += project.decisions.map { Item(kind: .decision, title: $0, context: project.name) }
        }
        for project in projects where project.blocked > 0 {
            items.append(Item(kind: .blocked,
                              title: String(localized: "\(project.blocked) task(s) blocked or failed"),
                              context: project.name))
        }
        return ThrottleWaitingSnapshot(items: items, computedAt: now)
    }

    /// One spoken sentence: the count, then at most three items by name.
    var spokenSummary: String {
        guard !items.isEmpty else { return String(localized: "Nothing waits on you.") }
        let named = items.prefix(3).map { item -> String in
            switch item.kind {
            case .question: String(localized: "\(item.context) asks a question")
            case .decision: String(localized: "decision in \(item.context): \(item.title)")
            case .blocked: String(localized: "\(item.context): \(item.title)")
            }
        }
        let list = named.formatted(.list(type: .and))
        return String(localized: "\(items.count) thing(s) wait on you: \(list).")
    }
}

enum ThrottleWaitingSnapshotStore {
    private static let key = "ThrottleWaitingSnapshotV1"
    private static var defaults: UserDefaults { UserDefaults(suiteName: ThrottleAppGroupID) ?? .standard }

    static func write(_ snapshot: ThrottleWaitingSnapshot) {
        guard read().items != snapshot.items, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    static func read() -> ThrottleWaitingSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(ThrottleWaitingSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}

struct GetWaitingIntent: AppIntent {
    static let title: LocalizedStringResource = "What waits on me"
    static let description = IntentDescription(
        "Say which Claude sessions ask a question, which decisions nobody settled and which plan work is blocked."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let snapshot = ThrottleWaitingSnapshotStore.read()
        guard snapshot.computedAt != .distantPast else {
            let unknown = String(localized: "Open Throttle once so it can see your sessions.")
            return .result(value: unknown, dialog: IntentDialog(stringLiteral: unknown))
        }
        let summary = snapshot.spokenSummary
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
