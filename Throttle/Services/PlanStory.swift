import Foundation

/// A task's log retold for a person: who did what, when, in sentences — the raw
/// NDJSON stays one disclosure away. The log is still the authority; this only
/// reads it, and never names a task by id or an author by its storage key.
enum PlanStory {

    /// `"claudeCode:98AFEFD7…"` → Claude Code, session 98AFEFD7.
    struct Actor: Equatable, Sendable {
        var name: String
        var session: String?
        /// The first letter of the runtime, for the small badge.
        var initial: String { String(name.prefix(1)).uppercased() }
    }

    static func actor(_ author: String) -> Actor {
        let parts = author.split(separator: ":", maxSplits: 1).map(String.init)
        let runtime = parts.first ?? author
        let name = AgentRuntime(rawValue: runtime)?.label
            ?? (runtime.lowercased() == "throttle" ? "Throttle" : runtime)
        let session = parts.count > 1 ? String(parts[1].prefix(8)) : nil
        return Actor(name: name, session: session)
    }

    /// Consecutive events by the same author: one card per stint of work.
    struct Chapter: Equatable, Sendable {
        var author: String
        var events: [TaskEvent]
        var actor: Actor { PlanStory.actor(author) }
        var start: Date? { events.first?.timestamp }
        var end: Date? { events.last?.timestamp }
    }

    static func chapters(_ events: [TaskEvent]) -> [Chapter] {
        var out: [Chapter] = []
        for event in events {
            if let last = out.last, last.author == event.author {
                out[out.count - 1].events.append(event)
            } else {
                out.append(Chapter(author: event.author, events: [event]))
            }
        }
        return out
    }

    /// One sentence per event. `parkedForReview` says whether the task's current
    /// state is a review — the only way to tell "complete" from "parked".
    static func sentence(_ event: TaskEvent, parkedForReview: Bool) -> String {
        workSentence(event, parkedForReview: parkedForReview)
            ?? lifecycleSentence(event)
            ?? throttleSentence(event)
    }

    /// What the agent produced.
    private static func workSentence(_ event: TaskEvent, parkedForReview: Bool) -> String? {
        switch event.type {
        case .progress:
            let pct = event.pct.map { "\($0)%" } ?? ""
            guard let note = event.note, !note.isEmpty else { return String(localized: "Progress \(pct)") }
            return String(localized: "Progress \(pct) — “\(note)”")
        case .evidence: return evidenceSentence(kind: event.kind, ref: event.ref)
        case .candidateComplete: return String(localized: "Said it is ready for Throttle's check")
        case .completed:
            return parkedForReview ? String(localized: "Marked complete → parked for review")
                                   : String(localized: "Marked complete")
        default: return nil
        }
    }

    /// Taking, blocking, failing, letting go.
    private static func lifecycleSentence(_ event: TaskEvent) -> String? {
        let reason = event.reason ?? String(localized: "no reason given")
        switch event.type {
        case .claimed: return String(localized: "Took the task")
        case .blocked: return String(localized: "Blocked — \(reason)")
        case .unblocked: return String(localized: "Unblocked")
        case .failed: return String(localized: "Failed — \(reason)")
        case .released: return String(localized: "Released the task")
        default: return nil
        }
    }

    /// Verdicts and what Throttle itself did.
    private static func throttleSentence(_ event: TaskEvent) -> String {
        switch event.type {
        case .verified: return String(localized: "Verified the work")
        case .rejected:
            return String(localized: "Rejected the work — \(event.reason ?? String(localized: "no reason given"))")
        case .checked:
            return event.passed == true ? String(localized: "Throttle's check passed")
                                        : String(localized: "Throttle's check failed")
        case .integrated: return String(localized: "Integrated into the base branch")
        case .verificationStarted: return String(localized: "Throttle started its check")
        case .verificationProcessAttached: return String(localized: "The check is running")
        case .verificationAbandoned: return String(localized: "The check was abandoned")
        default: return event.type.rawValue
        }
    }

    static func evidenceSentence(kind: String?, ref: String?) -> String {
        let name = ref.map { evidenceName(kind: kind, ref: $0) } ?? ""
        switch kind {
        case "commit": return String(localized: "Committed \(name)")
        case "report", "file": return String(localized: "Added the report \(name)")
        case "test": return String(localized: "Recorded a test run")
        default: return String(localized: "Added evidence \(name)")
        }
    }

    /// What an evidence card is called: a file's name, a commit's short SHA.
    static func evidenceName(kind: String?, ref: String) -> String {
        switch kind {
        case "commit": return String(ref.prefix(7))
        case "report", "file": return URL(fileURLWithPath: ref).lastPathComponent
        default: return ref.count > 60 ? String(ref.prefix(57)) + "…" : ref
        }
    }

    /// "09:12 → 09:41 · 29 min"
    static func span(_ start: Date?, _ end: Date?) -> String? {
        guard let start, let end else { return nil }
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let range = "\(clock(start)) → \(clock(end))"
        return minutes > 0 ? "\(range) · \(minutes) min" : range
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
