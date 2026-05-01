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
///   - free retry-on-malformed (Anthropic re-prompts the model when
///     it generates input that doesn't match our schema, instead of
///     us catching a parse error after the fact)
///   - structured arguments (no more "the model wrote 'PATH:' with
///     a typo" failure mode)
///   - proper multi-turn linkage via `tool_use_id` round-trip
enum ClaudeAPIKeyProtocol {

    /// One tool_use content block, as returned by the model and as we
    /// echo it back to Anthropic on the follow-up turn.
    struct ToolUseBlock: Sendable, Hashable {
        let id: String
        let name: String
        /// Flat string→string for our two tools — both take a single
        /// `path` argument. We keep it flat to avoid `Any`-typing the
        /// whole struct; if we add a third tool with richer arguments
        /// later we'll widen this then.
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
        return "\n```tool\nTOOL: \(block.name)\nPATH: \(path)\n```\n"
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

    /// Parse a sequence of `data:` JSON payloads from an Anthropic
    /// streaming response. Concatenates `input_json_delta` partials into
    /// each tool_use's full input JSON. Returns text deltas alongside
    /// tool_uses so the caller can stream both.
    static func parseSSEEvents(_ events: [String]) -> ParseResult {
        var texts: [String] = []
        // Per-content-block accumulators, keyed by index. Anthropic
        // identifies blocks by their position in the assistant's reply.
        struct InProgress {
            var id: String = ""
            var name: String = ""
            var jsonChunks: [String] = []
        }
        var inProgress: [Int: InProgress] = [:]
        var completed: [ToolUseBlock] = []

        for raw in events {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = obj["index"] as? Int,
                      let block = obj["content_block"] as? [String: Any],
                      block["type"] as? String == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String else { continue }
                inProgress[index] = InProgress(id: id, name: name, jsonChunks: [])

            case "content_block_delta":
                guard let index = obj["index"] as? Int,
                      let delta = obj["delta"] as? [String: Any],
                      let kind = delta["type"] as? String else { continue }
                if kind == "text_delta", let t = delta["text"] as? String {
                    texts.append(t)
                } else if kind == "input_json_delta",
                          let chunk = delta["partial_json"] as? String,
                          inProgress[index] != nil {
                    inProgress[index]!.jsonChunks.append(chunk)
                }

            case "content_block_stop":
                guard let index = obj["index"] as? Int,
                      let bag = inProgress.removeValue(forKey: index) else { continue }
                let fullJSON = bag.jsonChunks.joined()
                let parsed = parseInputMap(fullJSON)
                completed.append(ToolUseBlock(id: bag.id, name: bag.name, input: parsed))

            default:
                continue
            }
        }
        return ParseResult(textDeltas: texts, toolUses: completed)
    }

    /// Parse the accumulated input JSON for a tool_use into a flat
    /// string→string map. Robust to malformed JSON: returns an empty
    /// map rather than throwing, so the upstream pipeline can continue
    /// and surface "no path" via the fenced result.
    private static func parseInputMap(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    /// The static tool catalogue. Schemas are intentionally minimal —
    /// just `path` for both — because the model's job is to pick the
    /// path, and adding optional knobs widens the failure surface.
    static func toolDefinitions() -> [[String: Any]] {
        let pathSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute file or directory path to read or list, under the user's home directory."
                ]
            ],
            "required": ["path"]
        ]
        return [
            [
                "name": "read_file",
                "description": "Read the full contents of a file at the given absolute path. Returns the bytes (max 64 KB), or an error if missing/binary/over the cap.",
                "input_schema": pathSchema
            ],
            [
                "name": "list_files",
                "description": "List the immediate children of a directory at the given absolute path. Returns names, sizes, and modification times.",
                "input_schema": pathSchema
            ]
        ]
    }
}
