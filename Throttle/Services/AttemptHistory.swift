import Foundation

/// What earlier attempts on a task taught, read from its own log: why a verifier
/// sent it back, why it failed, what blocked it. Fed to the next agent's kickoff
/// so a retry does not repeat the same mistake (episodic reflection), and offered
/// to the person as a rule for CLAUDE.md — never written there without a click,
/// because durable instructions are the person's to own.
enum AttemptHistory {

    struct Lesson: Equatable, Sendable, Identifiable {
        let taskID: String
        let seq: Int
        let type: TaskEventType
        let text: String
        let occurredAt: Date
        var id: String { "\(taskID)#\(seq)" }
    }

    static let maximumTextLength = 300

    static func lessons(taskID: String, events: [TaskEvent]) -> [Lesson] {
        events.compactMap { event -> Lesson? in
            let text: String?
            switch event.type {
            case .rejected, .failed, .blocked:
                text = event.reason ?? event.summary ?? event.note
            case .checked where event.passed == false:
                text = event.summary ?? event.note ?? event.reason
            default:
                text = nil
            }
            guard let cleaned = text.map(clean), !cleaned.isEmpty else { return nil }
            return Lesson(taskID: taskID, seq: event.seq, type: event.type, text: cleaned, occurredAt: event.timestamp)
        }
    }

    /// The most recent lessons across a project, newest first.
    static func projectLessons(events: [String: [TaskEvent]], limit: Int = 5) -> [Lesson] {
        events.flatMap { lessons(taskID: $0.key, events: $0.value) }
            .sorted { $0.occurredAt != $1.occurredAt ? $0.occurredAt > $1.occurredAt : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    /// Kickoff lines for a retry. Empty on a first attempt, so a fresh task's
    /// prompt stays exactly as it was.
    static func kickoffLines(_ lessons: [Lesson], limit: Int = 3) -> [String] {
        let recent = lessons.suffix(limit)
        guard !recent.isEmpty else { return [] }
        return ["", "Earlier attempts on this task did not pass. Do not repeat these:"]
            + recent.map { "  - \(word($0.type)): \($0.text)" }
    }

    static let claudeMdHeading = "## Lessons recorded by Throttle"

    /// Appends one lesson under its own heading in the project's CLAUDE.md.
    /// Returns false when the same line is already there.
    @discardableResult
    static func appendToClaudeMd(_ lesson: Lesson, projectRoot: URL) throws -> Bool {
        let file = projectRoot.appending(path: "CLAUDE.md")
        var content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let line = "- \(lesson.text) (from \(lesson.taskID))"
        guard !content.contains(line) else { return false }
        if !content.contains(claudeMdHeading) {
            if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
            content += (content.isEmpty ? "" : "\n") + claudeMdHeading + "\n\n"
        } else if !content.hasSuffix("\n") {
            content += "\n"
        }
        content += line + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    private static func clean(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > maximumTextLength ? String(flat.prefix(maximumTextLength)) + "…" : flat
    }

    private static func word(_ type: TaskEventType) -> String {
        switch type {
        case .rejected: "rejected by review"
        case .failed: "failed"
        case .blocked: "blocked"
        default: "verification failed"
        }
    }
}
