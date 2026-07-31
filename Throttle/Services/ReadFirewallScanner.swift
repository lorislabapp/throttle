import Foundation

/// Detects brute-force file loading in Claude Code JSONL transcripts.
///
/// A "turn" starts with a real user prompt and includes the assistant's tool calls
/// plus their `tool_result` messages. Tool-result user messages do not start a new
/// turn. This distinction matters because Claude commonly emits one Read per
/// assistant event, interleaved with results.
enum ReadFirewallScanner {
    struct Summary: Sendable, Equatable {
        var heavyTurns = 0
        var oversizedTurns = 0
        var totalReads = 0
        var loadedBytes = 0
        var topFile: String?
        var topFileCount = 0
        var since: Date?

        var highWaste: Bool { heavyTurns > 0 || oversizedTurns > 0 }
        var hasData: Bool { highWaste }
    }

    static let heavyThreshold = 3
    static let byteThreshold = 150 * 1_024
    private static let windowDays = 14.0
    private static let reReadFloor = 4
    private static let readNames: Set<String> = ["Read", "read_file"]

    private struct Turn {
        var consecutiveReads = 0
        var maxConsecutiveReads = 0
        var loadedBytes = 0
    }

    /// Pure scanner used by tests and by the file-system scan.
    static func scan(lines: [String]) -> Summary {
        var summary = Summary()
        var turn = Turn()
        var hasTurnActivity = false
        var readToolIDs: Set<String> = []
        var fileCounts: [String: Int] = [:]

        func finishTurn() {
            guard hasTurnActivity else { return }
            if turn.maxConsecutiveReads >= heavyThreshold { summary.heavyTurns += 1 }
            if turn.loadedBytes > byteThreshold { summary.oversizedTurns += 1 }
            summary.loadedBytes += turn.loadedBytes
            turn = Turn()
            hasTurnActivity = false
            readToolIDs.removeAll(keepingCapacity: true)
        }

        for raw in lines {
            guard let data = raw.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = root["message"] as? [String: Any] else { continue }
            let role = message["role"] as? String
            let blocks = contentBlocks(message["content"])

            // Only a genuine human message closes the prior tool loop. Claude
            // records tool results with role=user too, so inspect their content.
            if role == "user", !blocks.isEmpty,
               blocks.contains(where: { ($0["type"] as? String) != "tool_result" }) {
                finishTurn()
            } else if role == "user", blocks.isEmpty,
                      message["content"] is String {
                finishTurn()
            }

            var sawToolUse = false
            for block in blocks where (block["type"] as? String) == "tool_use" {
                sawToolUse = true
                hasTurnActivity = true
                let name = block["name"] as? String ?? ""
                if readNames.contains(name) {
                    summary.totalReads += 1
                    turn.consecutiveReads += 1
                    turn.maxConsecutiveReads = max(turn.maxConsecutiveReads, turn.consecutiveReads)
                    if let id = block["id"] as? String { readToolIDs.insert(id) }
                    if let input = block["input"] as? [String: Any],
                       let path = (input["file_path"] ?? input["path"]) as? String {
                        fileCounts[(path as NSString).lastPathComponent, default: 0] += 1
                    }
                } else {
                    turn.consecutiveReads = 0
                }
            }

            // Attribute bytes only to results of Read/read_file calls. This is an
            // exact UTF-8 byte count, not a fabricated token estimate.
            for block in blocks where (block["type"] as? String) == "tool_result" {
                guard let id = block["tool_use_id"] as? String,
                      readToolIDs.contains(id) else { continue }
                hasTurnActivity = true
                turn.loadedBytes += payloadBytes(block["content"])
            }

            // An assistant event containing a non-read tool breaks sequentiality.
            if sawToolUse {
                let names = blocks.compactMap { block -> String? in
                    guard (block["type"] as? String) == "tool_use" else { return nil }
                    return block["name"] as? String
                }
                if names.contains(where: { !readNames.contains($0) }) {
                    turn.consecutiveReads = 0
                }
            }
        }
        finishTurn()

        if let top = fileCounts.max(by: { $0.value < $1.value }), top.value >= reReadFloor {
            summary.topFile = top.key
            summary.topFileCount = top.value
        }
        return summary
    }

    /// Best-effort scan of a project's recent local transcripts.
    static func scan(encodedName: String) -> Summary {
        var aggregate = Summary()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encodedName)", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return aggregate }

        let cutoff = Date().addingTimeInterval(-windowDays * 86_400)
        var topCounts: [String: Int] = [:]
        var earliest: Date?
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard modified >= cutoff,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            earliest = min(earliest ?? modified, modified)
            let part = scan(lines: text.split(separator: "\n").map(String.init))
            aggregate.heavyTurns += part.heavyTurns
            aggregate.oversizedTurns += part.oversizedTurns
            aggregate.totalReads += part.totalReads
            aggregate.loadedBytes += part.loadedBytes
            if let file = part.topFile { topCounts[file, default: 0] += part.topFileCount }
        }
        if let top = topCounts.max(by: { $0.value < $1.value }) {
            aggregate.topFile = top.key
            aggregate.topFileCount = top.value
        }
        aggregate.since = earliest
        return aggregate
    }

    private static func contentBlocks(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func payloadBytes(_ value: Any?) -> Int {
        if let text = value as? String { return text.utf8.count }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
        return data.count
    }
}
