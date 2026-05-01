import XCTest
@testable import Throttle

/// Pure-function tests for the BYO Claude API key path's native
/// tool_use protocol. These cover request construction and SSE response
/// parsing — the two places where bugs would silently corrupt a chat
/// turn. The actual URLSession call is integration-level and lives
/// inside `ClaudeAPIKeyProvider.streamChat`; we don't network-test here.
final class ClaudeAPIKeyProtocolTests: XCTestCase {

    // MARK: - Request body construction

    func test_buildRequestBody_includesToolDefinitionsForReadFileAndListFiles() throws {
        let messages = [ChatMessage(role: .user, content: "audit my setup")]
        let body = ClaudeAPIKeyProtocol.buildRequestBody(
            messages: messages,
            system: "You are an auditor.",
            model: "claude-opus-4-7",
            priorToolUses: []
        )

        guard let tools = body["tools"] as? [[String: Any]] else {
            return XCTFail("expected tools array in request body, got \(body["tools"] ?? "nil")")
        }
        let names = tools.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["list_files", "read_file"])

        // Each tool must have an input_schema with a `path` property —
        // both our tools take an absolute path.
        for tool in tools {
            guard let schema = tool["input_schema"] as? [String: Any],
                  let props = schema["properties"] as? [String: Any] else {
                XCTFail("tool \(tool["name"] ?? "?") missing input_schema.properties")
                continue
            }
            XCTAssertNotNil(props["path"], "tool \(tool["name"] ?? "?") missing `path` parameter")
        }
    }

    // MARK: - SSE response parsing

    func test_parseSSEEvents_extractsSingleToolUseAndItsAccumulatedJSON() throws {
        // Anthropic streams a tool_use as: content_block_start (with the
        // id+name), then a series of input_json_delta partial_json strings
        // that the client must concatenate into the final input JSON,
        // then content_block_stop.
        let events = [
            #"{"type":"message_start","message":{"id":"msg_01","model":"claude-opus-4-7"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_ABC","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":":\"/Users/kev/.claude/settings.json\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"message_stop"}"#
        ]

        let result = ClaudeAPIKeyProtocol.parseSSEEvents(events)

        XCTAssertEqual(result.toolUses.count, 1)
        XCTAssertEqual(result.toolUses.first?.id, "toolu_ABC")
        XCTAssertEqual(result.toolUses.first?.name, "read_file")
        XCTAssertEqual(result.toolUses.first?.input["path"], "/Users/kev/.claude/settings.json")
    }

    func test_parseSSEEvents_extractsMultipleToolUsesInOrder() throws {
        // Two tool_use blocks emitted in the same assistant turn — we
        // need both, in the order they came from the model, so the
        // recursion layer fires the reads in the order the model planned.
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_FIRST","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/a/CLAUDE.md\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_SECOND","name":"list_files","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/a/.claude/hooks/\"}"}}"#,
            #"{"type":"content_block_stop","index":1}"#
        ]

        let result = ClaudeAPIKeyProtocol.parseSSEEvents(events)

        XCTAssertEqual(result.toolUses.map(\.id), ["toolu_FIRST", "toolu_SECOND"])
        XCTAssertEqual(result.toolUses.map(\.name), ["read_file", "list_files"])
        XCTAssertEqual(result.toolUses[0].input["path"], "/a/CLAUDE.md")
        XCTAssertEqual(result.toolUses[1].input["path"], "/a/.claude/hooks/")
    }

    func test_parseSSEEvents_handlesMalformedInputJSON_returnsEmptyInputNotCrash() throws {
        // The model can occasionally emit input_json_delta chunks that
        // never form valid JSON when concatenated (e.g. truncation,
        // mid-flight cancel). The parser must NOT throw; it should
        // surface the tool_use with an empty input so downstream code
        // can refuse the call cleanly with a "no path" error instead
        // of crashing the whole turn.
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_BAD","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\""}}"#,
            #"{"type":"content_block_stop","index":0}"#
        ]
        let result = ClaudeAPIKeyProtocol.parseSSEEvents(events)
        XCTAssertEqual(result.toolUses.count, 1)
        XCTAssertEqual(result.toolUses.first?.id, "toolu_BAD")
        XCTAssertTrue(result.toolUses.first?.input.isEmpty ?? false,
                      "malformed JSON should yield empty input map, got \(result.toolUses.first?.input ?? [:])")
    }

    // MARK: - Fenced output rendering

    func test_renderAsFencedBlock_emitsExactFormatExistingParserExpects() throws {
        // The recursion layer in ProjectAssistantTab uses
        // AssistantToolCallParser to extract `tool` blocks from the
        // streamed assistant text. The fenced format the parser expects
        // is exactly:
        //
        //     ```tool
        //     TOOL: <name>
        //     PATH: <path>
        //     ```
        //
        // So we render every native tool_use back into that form. The
        // recursion code path then doesn't change.
        let block = ClaudeAPIKeyProtocol.ToolUseBlock(
            id: "toolu_X",
            name: "read_file",
            input: ["path": "/Users/kev/.claude/settings.json"]
        )
        let rendered = ClaudeAPIKeyProtocol.renderAsFencedBlock(block)

        // Round-trip check: feeding our output through the existing
        // parser should produce one tool call with the right name+path.
        let parsed = AssistantToolCallParser.extract(from: rendered)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.tool, .readFile)
        XCTAssertEqual(parsed.first?.path, "/Users/kev/.claude/settings.json")
    }

    // MARK: - Multi-turn message rebuild

    func test_rebuildMessages_lastAssistantToolUseAndUserToolResultGoNative() throws {
        // Transcript shape after one tool round-trip in ProjectAssistantTab:
        //   [0] user "audit"
        //   [1] assistant "<text> + fenced ```tool block"
        //   [2] user "[tool_result for read_file (/foo)]\n<bytes>"
        // The provider has cached the tool_use_id from turn 1's response.
        // Rebuild must produce native tool_use + tool_result for the
        // LAST pair so the model gets a coherent multi-turn chain.
        let transcript = [
            ChatMessage(role: .user, content: "audit my setup"),
            ChatMessage(role: .assistant, content:
                "I'll check the settings file.\n\n```tool\nTOOL: read_file\nPATH: /foo/settings.json\n```\n"),
            ChatMessage(role: .user, content:
                "[tool_result for read_file (/foo/settings.json)]\n[/foo/settings.json, 42 bytes]\n{\"permissions\":{}}")
        ]
        let priorToolUses = [
            ClaudeAPIKeyProtocol.ToolUseBlock(
                id: "toolu_X",
                name: "read_file",
                input: ["path": "/foo/settings.json"]
            )
        ]

        let rebuilt = ClaudeAPIKeyProtocol.rebuildMessages(
            transcript: transcript,
            priorToolUses: priorToolUses
        )

        XCTAssertEqual(rebuilt.count, 3, "three transcript messages should map to three API messages")

        // [0] user audit — plain text
        XCTAssertEqual(rebuilt[0]["role"] as? String, "user")
        XCTAssertEqual(rebuilt[0]["content"] as? String, "audit my setup")

        // [1] assistant — native blocks: text + tool_use
        XCTAssertEqual(rebuilt[1]["role"] as? String, "assistant")
        guard let asstBlocks = rebuilt[1]["content"] as? [[String: Any]] else {
            return XCTFail("assistant content should be an array of native blocks, got \(rebuilt[1]["content"] ?? "nil")")
        }
        XCTAssertEqual(asstBlocks.count, 2, "expected text + tool_use")
        XCTAssertEqual(asstBlocks[0]["type"] as? String, "text")
        XCTAssertTrue((asstBlocks[0]["text"] as? String)?.contains("I'll check") ?? false)
        XCTAssertEqual(asstBlocks[1]["type"] as? String, "tool_use")
        XCTAssertEqual(asstBlocks[1]["id"] as? String, "toolu_X")
        XCTAssertEqual(asstBlocks[1]["name"] as? String, "read_file")
        XCTAssertEqual((asstBlocks[1]["input"] as? [String: String])?["path"], "/foo/settings.json")

        // [2] user — native tool_result block linking to toolu_X
        XCTAssertEqual(rebuilt[2]["role"] as? String, "user")
        guard let userBlocks = rebuilt[2]["content"] as? [[String: Any]] else {
            return XCTFail("user content should be an array, got \(rebuilt[2]["content"] ?? "nil")")
        }
        XCTAssertEqual(userBlocks.count, 1)
        XCTAssertEqual(userBlocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(userBlocks[0]["tool_use_id"] as? String, "toolu_X")
        // The result content must include the actual bytes, not the
        // [/foo, 42 bytes] header line we use for human-readable framing.
        XCTAssertTrue((userBlocks[0]["content"] as? String)?.contains("permissions") ?? false)
    }

    func test_rebuildMessages_noPriorToolUses_isPlainTextThroughout() throws {
        // First turn — no cache, no native blocks. Every message stays
        // as plain text content. This is the path Anthropic also takes
        // when there's nothing to round-trip.
        let transcript = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "hello"),
            ChatMessage(role: .user, content: "follow up")
        ]
        let rebuilt = ClaudeAPIKeyProtocol.rebuildMessages(
            transcript: transcript,
            priorToolUses: []
        )
        XCTAssertEqual(rebuilt.count, 3)
        for msg in rebuilt {
            XCTAssertTrue(msg["content"] is String,
                          "expected plain string content when no priorToolUses, got \(type(of: msg["content"]!))")
        }
    }

    func test_parseSSEEvents_handlesEmptyInputObject() throws {
        // The model emits {} sometimes when it "forgets" the argument.
        // We accept it as a tool_use with empty input — same shape as
        // the malformed case from the executor's POV.
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_EMPTY","name":"list_files","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            #"{"type":"content_block_stop","index":0}"#
        ]
        let result = ClaudeAPIKeyProtocol.parseSSEEvents(events)
        XCTAssertEqual(result.toolUses.count, 1)
        XCTAssertEqual(result.toolUses.first?.input, [:])
    }
}
