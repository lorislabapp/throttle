import Foundation

/// Pure functions for the BYO Claude API key path's native tool_use
/// protocol. Lives separately from `ClaudeAPIKeyProvider` so the bits
/// that don't need URLSession can be unit-tested cheaply.
///
/// Why native tool_use here but not in the other two providers?
/// Apple Intelligence and the Safari Bridge can't emit native
/// `tool_use` content blocks — `FoundationModels` exposes a different
/// `Tool` protocol, and claude.ai's web app renders blocks back to
/// text in the SSE stream we read. Our fenced ```tool format stays
/// the lowest-common-denominator for those two. For the API key
/// provider specifically, going native gives us:
///
/// Invalid arguments and incomplete streams are rejected locally; structured
/// output is not a guarantee of valid content or automatic provider retries.
///
///   - structured arguments (no more "the model wrote 'PATH:' with
///     a typo" failure mode)
///   - proper multi-turn linkage via `tool_use_id` round-trip
enum ClaudeAPIKeyProtocol {

    /// One tool_use content block, as returned by the model and as we
    /// echo it back to Anthropic on the follow-up turn.
    struct ToolUseBlock: Sendable, Hashable {
        let id: String
        let name: String
        /// Flat string arguments for the project read/list/search tools.
        let input: [String: String]
    }

    /// Construct the JSON body for `POST /v1/messages`. Returns a plain
    /// `[String: Any]` so the caller can `JSONSerialization.data(...)`.
    /// `priorToolUses` is non-empty on follow-up turns: the caller has
    /// the assistant's tool_use blocks from the previous turn and the
    /// user's tool_result text in `messages.last`. We translate that
    /// pair back into the native shape the API expects so the model
    /// sees a coherent multi-turn chain.
    static func buildRequestBody(
        messages: [ChatMessage],
        system: String,
        model: String,
        priorToolUses: [ToolUseBlock] = []
    ) -> [String: Any] {
        return [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "tools": toolDefinitions(),
            "messages": rebuildMessages(transcript: messages, priorToolUses: priorToolUses)
        ]
    }

    /// Build the Anthropic-format `messages` array from Throttle's
    /// transcript. When `priorToolUses` is non-empty, the LAST
    /// assistant→user pair is upgraded to native tool_use + tool_result
    /// blocks (with the cached `tool_use_id`s linking them). Earlier
    /// turns stay as plain string content — the model still has them
    /// in context, just less structured. We only need the most recent
    /// pair to be properly typed because that's what carries the
    /// active tool_use_id the API will validate against.
    static func rebuildMessages(
        transcript: [ChatMessage],
        priorToolUses: [ToolUseBlock]
    ) -> [[String: Any]] {
        let nonSystem = transcript.filter { $0.role != .system }
        // No tool round-trip in flight → plain text everywhere.
        guard !priorToolUses.isEmpty,
              nonSystem.count >= 2,
              nonSystem.last?.role == .user,
              nonSystem.dropLast().last?.role == .assistant else {
            return nonSystem.map { ["role": $0.role.rawValue, "content": $0.content] }
        }

        var out: [[String: Any]] = []
        let upgradeIndices = (nonSystem.count - 2, nonSystem.count - 1)

        for (i, msg) in nonSystem.enumerated() {
            if i == upgradeIndices.0 {
                // Assistant: text + tool_use blocks.
                let text = stripFencedToolBlocks(msg.content)
                var blocks: [[String: Any]] = []
                if !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for use in priorToolUses {
                    blocks.append([
                        "type": "tool_use",
                        "id": use.id,
                        "name": use.name,
                        "input": use.input
                    ])
                }
                out.append(["role": "assistant", "content": blocks])
            } else if i == upgradeIndices.1 {
                // User: tool_result blocks. Pair tool_results with
                // priorToolUses by ORDER — same recursion produced both
                // in the same sequence in `runAssistantTurn`.
                let resultPayloads = splitToolResultPayloads(msg.content)
                var blocks: [[String: Any]] = []
                for (idx, use) in priorToolUses.enumerated() {
                    let content = idx < resultPayloads.count
                        ? resultPayloads[idx]
                        : "(no result captured)"
                    blocks.append([
                        "type": "tool_result",
                        "tool_use_id": use.id,
                        "content": content
                    ])
                }
                out.append(["role": "user", "content": blocks])
            } else {
                out.append(["role": msg.role.rawValue, "content": msg.content])
            }
        }
        return out
    }

    /// Render a native tool_use block back into the fenced ```tool
    /// format the recursion layer in `ProjectAssistantTab` already
    /// understands. This bridges native ↔ fenced so we get the API
    /// schema validation upside of native without rewriting the
    /// recursion plumbing.
    static func renderAsFencedBlock(_ block: ToolUseBlock) -> String {
        let path = block.input["path"] ?? ""
        let query = block.input["query"] ?? ""
        guard ["read_file", "list_files", "search_files"].contains(block.name),
              [path, query].allSatisfy({
                  $0.rangeOfCharacter(from: .controlCharacters) == nil && !$0.contains("```")
              }) else {
            return "Error: invalid project tool arguments."
        }
        let queryField = block.name == "search_files" ? "\nQUERY: \(query)" : ""
        return "\n```tool\nTOOL: \(block.name)\nPATH: \(path)\(queryField)\n```\n"
    }

    /// Strip every fenced ```tool block from an assistant message,
    /// preserving the surrounding prose. The native `tool_use` blocks
    /// carry the structured info — we don't want them duplicated as
    /// text in the same content array.
    private static func stripFencedToolBlocks(_ s: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: "```tool[\\s\\S]*?```",
            options: []
        ) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let stripped = re.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull the per-tool payload out of Throttle's synthetic user
    /// message. The format is:
    ///
    ///     [tool_result for read_file (/foo)]
    ///     [/foo, 42 bytes]
    ///     <bytes>
    ///
    ///     ---
    ///
    ///     [tool_result for ...]
    ///     ...
    ///
    /// We return the bytes section for each block in order, with the
    /// `[/foo, N bytes]` framing line and the `[tool_result ...]`
    /// header stripped. The header info is redundant once we put the
    /// content into a native `tool_result` block keyed by `tool_use_id`.
    private static func splitToolResultPayloads(_ s: String) -> [String] {
        let blocks = s.components(separatedBy: "\n\n---\n\n")
        return blocks.map { block in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.first?.hasPrefix("[tool_result") == true { lines.removeFirst() }
            if lines.first?.hasPrefix("[") == true && lines.first?.contains(" bytes]") == true {
                lines.removeFirst()
            }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Result of parsing a stream of SSE event payloads. Text deltas
    /// belong in the streamed user-facing chat bubble; tool_uses are
    /// what we then translate into fenced ```tool blocks for the
    /// existing recursion layer in `ProjectAssistantTab`.
    struct ParseResult: Sendable {
        let textDeltas: [String]
        let toolUses: [ToolUseBlock]
    }

    /// Same project capability catalogue for native and fenced providers.
    static func toolDefinitions() -> [[String: Any]] {
        [AssistantTool.readFile, .listFiles, .searchFiles].map { tool in
            var properties: [String: Any] = [
                "path": ["type": "string", "description": "Path relative to the selected project; . for root."]
            ]
            var required = ["path"]
            if tool == .searchFiles {
                properties["query"] = ["type": "string", "description": "Literal search text, at most 256 characters."]
                required.append("query")
            }
            return ["name": tool.rawValue, "description": tool.description,
                    "input_schema": ["type": "object", "properties": properties,
                                     "required": required, "additionalProperties": false]]
        }
    }
}

extension ClaudeAPIKeyProtocol {
    enum StreamFailure: Error, Equatable, LocalizedError {
        case incomplete, malformed, remoteError, limitExceeded
        var errorDescription: String? {
            switch self {
            case .incomplete: String(localized: "Claude response was incomplete; no tools were admitted.")
            case .malformed: String(localized: "Claude response was malformed; no tools were admitted.")
            case .remoteError: String(localized: "Claude reported a streaming error; no tools were admitted.")
            case .limitExceeded: String(localized: "Claude response exceeded the local stream limit.")
            }
        }
    }

    /// Bound bytes before UTF-8/JSON decoding, including comments and long lines.
    /// SSE frames dispatch only at their blank line, including multi-line data.
    struct EventBuffer {
        static let maximumBytes = 8 * 1024 * 1024
        static let maximumEvents = 20_000
        static let maximumLineBytes = 256 * 1024
        private var bytes = 0
        private var line: [UInt8] = []
        private var dataLines: [String] = []
        private var eventName: String?
        private(set) var events: [String] = []

        mutating func append(_ byte: UInt8) throws -> String? {
            guard bytes < Self.maximumBytes else { throw StreamFailure.limitExceeded }
            bytes += 1
            guard byte == 10 else {
                guard line.count < Self.maximumLineBytes else { throw StreamFailure.limitExceeded }
                line.append(byte)
                return nil
            }
            if line.last == 13 { line.removeLast() }
            guard let value = String(bytes: line, encoding: .utf8) else { throw StreamFailure.malformed }
            line.removeAll(keepingCapacity: true)
            return try consumeLine(value)
        }

        private mutating func finishFrame() throws -> String? {
            defer { dataLines.removeAll(keepingCapacity: true); eventName = nil }
            guard !dataLines.isEmpty else { return nil }
            guard events.count < Self.maximumEvents else { throw StreamFailure.limitExceeded }
            let payload = dataLines.joined(separator: "\n")
            let object = try Self.object(payload)
            if let eventName, object["type"] as? String != eventName { throw StreamFailure.malformed }
            guard object["type"] as? String != "error" else { throw StreamFailure.remoteError }
            events.append(payload)
            return payload
        }

        private mutating func consumeLine(_ value: String) throws -> String? {
            if value.isEmpty { return try finishFrame() }
            if value.hasPrefix("data:") {
                let field = value.dropFirst(5)
                dataLines.append(String(field.first == " " ? field.dropFirst() : field))
            } else if value.hasPrefix("event:") {
                eventName = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        func finish() throws -> ParseResult {
            guard line.isEmpty, dataLines.isEmpty, eventName == nil else { throw StreamFailure.incomplete }
            return try parseSSEEvents(events)
        }

        fileprivate static func object(_ raw: String) throws -> [String: Any] {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] is String else { throw StreamFailure.malformed }
            return object
        }
    }

    /// Anthropic's terminal message_stop, not transport EOF, closes a response.
    /// https://platform.claude.com/docs/en/build-with-claude/streaming
    static func parseSSEEvents(_ events: [String]) throws -> ParseResult {
        guard events.count <= EventBuffer.maximumEvents,
              events.reduce(0, { $0 + $1.utf8.count }) <= EventBuffer.maximumBytes else {
            throw StreamFailure.limitExceeded
        }
        var state = ParseState()
        for raw in events { try state.consume(raw) }
        return try state.result()
    }

    private struct Block {
        var id: String?
        var name: String?
        var kind: String
        var json = ""
    }

    private struct ParseState {
        private var texts: [String] = [], tools: [ToolUseBlock] = []
        private var active: [Int: Block] = [:], seen: Set<Int> = []
        private var started = false
        private(set) var stopped = false
        private var stopReason: String?

        mutating func consume(_ raw: String) throws {
            let object = try EventBuffer.object(raw)
            let type = object["type"] as? String ?? ""
            if type == "error" { throw StreamFailure.remoteError }
            if type == "ping" { return }
            guard !stopped else { throw StreamFailure.malformed }
            switch type {
            case "message_start": try startMessage(object)
            case "content_block_start": try startBlock(object)
            case "content_block_delta": try appendDelta(object)
            case "content_block_stop": try finishBlock(object)
            case "message_delta": try updateMessage(object)
            case "message_stop": try finishMessage(object)
            default: break // Forward-compatible unknown event types, bounded above.
            }
        }

        private mutating func startMessage(_ object: [String: Any]) throws {
            guard !started, object["message"] is [String: Any] else { throw StreamFailure.malformed }
            started = true
        }

        private mutating func startBlock(_ object: [String: Any]) throws {
            guard started, stopReason == nil, let index = object["index"] as? Int, index >= 0,
                  seen.insert(index).inserted,
                  let block = object["content_block"] as? [String: Any],
                  let kind = block["type"] as? String else { throw StreamFailure.malformed }
            let id = block["id"] as? String, name = block["name"] as? String
            if kind == "tool_use", id?.isEmpty != false || name?.isEmpty != false {
                throw StreamFailure.malformed
            }
            active[index] = Block(id: id, name: name, kind: kind)
        }

        private mutating func appendDelta(_ object: [String: Any]) throws {
            guard let index = object["index"] as? Int, var block = active[index],
                  let delta = object["delta"] as? [String: Any],
                  let kind = delta["type"] as? String else { throw StreamFailure.malformed }
            if kind == "text_delta" {
                guard block.kind == "text", let text = delta["text"] as? String else {
                    throw StreamFailure.malformed
                }
                texts.append(text)
            } else if kind == "input_json_delta" {
                guard block.kind == "tool_use", let partial = delta["partial_json"] as? String else {
                    throw StreamFailure.malformed
                }
                block.json += partial
                active[index] = block
            }
        }

        private mutating func finishBlock(_ object: [String: Any]) throws {
            guard let index = object["index"] as? Int,
                  let block = active.removeValue(forKey: index) else { throw StreamFailure.malformed }
            if block.kind == "tool_use", let id = block.id, let name = block.name {
                guard !tools.contains(where: { $0.id == id }) else { throw StreamFailure.malformed }
                let data = Data(block.json.utf8)
                guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    throw StreamFailure.malformed
                }
                tools.append(ToolUseBlock(id: id, name: name, input: input))
            }
        }

        private mutating func updateMessage(_ object: [String: Any]) throws {
            guard started, active.isEmpty, let delta = object["delta"] as? [String: Any] else {
                throw StreamFailure.malformed
            }
            if let reason = delta["stop_reason"] as? String { stopReason = reason }
        }

        private mutating func finishMessage(_ object: [String: Any]) throws {
            guard started, active.isEmpty,
                  let stopReason, ["end_turn", "stop_sequence", "tool_use"].contains(stopReason),
                  tools.isEmpty || stopReason == "tool_use" else { throw StreamFailure.incomplete }
            stopped = true
        }

        func result() throws -> ParseResult {
            guard stopped else { throw StreamFailure.incomplete }
            return ParseResult(textDeltas: texts, toolUses: tools)
        }
    }
}
