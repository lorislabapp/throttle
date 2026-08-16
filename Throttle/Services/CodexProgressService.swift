import Foundation

struct CodexProgressSnapshot: Sendable, Equatable {
    enum Phase: String, Sendable {
        case starting
        case working
        case waiting
        case completed
        case failed
    }

    let phase: Phase
    let title: String
    let commandsCompleted: Int
}

/// Projects structured Codex rollout events into a short, privacy-preserving
/// state. Raw prompts, reasoning and terminal output are never copied here.
enum CodexProgressService {
    private static let tailBytes: UInt64 = 512 * 1024

    nonisolated static func latest(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL? = nil,
        rolloutURLs: [URL]? = nil,
        now: Date = Date()
    ) -> CodexProgressSnapshot? {
        let root = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        for url in rolloutURLs ?? CodexUsageService.recentRolloutURLs(root: root, now: now) {
            guard owns(url: url, sessionID: sessionID, cwd: cwd) else { continue }
            return snapshot(from: url)
        }
        return nil
    }

    nonisolated private static func owns(url: URL, sessionID: String, cwd: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n").prefix(12) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { continue }
            return payload["id"] as? String == sessionID && payload["cwd"] as? String == cwd
        }
        return false
    }

    nonisolated static func snapshot(from url: URL) -> CodexProgressSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n").map { Data($0.utf8) }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return decode(lines)
    }

    nonisolated static func decode(_ lines: [Data]) -> CodexProgressSnapshot? {
        var progress: CodexProgressSnapshot?
        var commands = 0
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let envelope = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            let type = payload["type"] as? String ?? ""
            switch (envelope, type) {
            case ("event_msg", "task_started"), ("event_msg", "turn_started"):
                progress = .init(phase: .working, title: "Analyzing", commandsCompleted: commands)
            case ("event_msg", "task_complete"), ("event_msg", "turn_completed"):
                progress = .init(phase: .completed, title: "Ready for review", commandsCompleted: commands)
            case ("event_msg", "turn_aborted"), ("event_msg", "error"):
                progress = .init(phase: .failed, title: "Session interrupted", commandsCompleted: commands)
            case ("event_msg", "item_completed"):
                commands += 1
                progress = .init(phase: .working, title: "Analyzing output", commandsCompleted: commands)
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                let name = payload["name"] as? String ?? ""
                let waiting = name == "request_user_input"
                progress = .init(
                    phase: waiting ? .waiting : .working,
                    title: waiting ? "Action required" : "Tool running",
                    commandsCompleted: commands
                )
            default:
                continue
            }
        }
        return progress
    }
}
