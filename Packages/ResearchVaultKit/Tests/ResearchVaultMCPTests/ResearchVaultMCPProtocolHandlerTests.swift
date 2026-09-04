import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultMCP
import ResearchVaultModel
import ResearchVaultSQLCipher
import Testing

@Suite("Research Vault MCP protocol")
struct ResearchVaultMCPProtocolHandlerTests {
    @Test("lists closed tools and returns citation-first search content")
    func protocolRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x71, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let text = "# MCP\n\nCitation protocol sentinel."
        let bytes = Data(text.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try await store.importDocument(
            ResearchDocumentCandidate(
                documentID: "dr-mcp", title: "MCP evidence", projectKey: "throttle",
                category: "test", libraryPath: "library/test/throttle/mcp.md",
                origins: ["/origin/mcp.md"], content: text, plaintextSHA256: hash,
                byteCount: bytes.count, modifiedAt: Date(timeIntervalSince1970: 1_787_832_000),
                sensitivity: .internal
            ),
            authorization: authorization,
            reviewState: .approved
        )
        let handler = ResearchVaultMCPProtocolHandler(
            gateway: ResearchVaultGateway(store: store, authorization: authorization)
        )

        let list = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8
        )))
        let listText = String(decoding: list, as: UTF8.self)
        #expect(listText.contains("research_vault_search"))
        #expect(listText.contains("additionalProperties\":false"))

        let search = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":"s","method":"tools/call","params":{"name":"research_vault_search","arguments":{"query":"protocol sentinel"}}}"#.utf8
        )))
        let searchText = String(decoding: search, as: UTF8.self)
        #expect(searchText.contains("dr-mcp"))
        #expect(searchText.contains(hash))
        #expect(searchText.contains("/origin/mcp.md"))
        #expect(!searchText.contains("isError\":true"))
    }

    @Test("rejects unknown tools without reflecting hostile input")
    func unknownTool() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-error-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x72, count: 32)
        )
        let handler = ResearchVaultMCPProtocolHandler(gateway: ResearchVaultGateway(
            store: store,
            authorization: VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        ))
        let hostile = "steal-secret-" + UUID().uuidString
        let request = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"\(hostile)\",\"arguments\":{}}}"
        let response = try #require(await handler.handleLine(Data(request.utf8)))
        let text = String(decoding: response, as: UTF8.self)
        #expect(text.contains("Unknown tool"))
        #expect(!text.contains(hostile))
    }

    @Test("supports stateless discovery, quarantined submit and cited resources")
    func modernWriteAndResources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-modern-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x73, count: 32)
        )
        let authorization = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let handler = ResearchVaultMCPProtocolHandler(gateway: gateway)

        let discover = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":3,"method":"server/discover"}"#.utf8
        )))
        let discoverText = String(decoding: discover, as: UTF8.self)
        #expect(discoverText.contains("2026-07-28"))
        #expect(discoverText.contains("2024-11-05"))
        #expect(discoverText.contains("resources"))

        let source = ResearchSource(
            id: "source/one", kind: .file, locator: "/evidence/source.txt",
            observedAt: Date(timeIntervalSince1970: 1_787_832_100),
            sha256: String(repeating: "a", count: 64)
        )
        let receipt = try ResearchReceipt.seal(
            receiptID: "15c13fb9-d9e1-4de1-bbf7-a329f21b8a4f",
            sessionID: "session-modern", agentID: "child-agent", parentAgentID: "parent-agent",
            projectKey: "throttle", question: "Modern MCP candidate",
            findings: [.init(claim: "Candidate claim", status: .supported, evidenceIDs: [source.id])],
            sources: [source], sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_200)
        )
        let receiptEncoder = JSONEncoder()
        receiptEncoder.dateEncodingStrategy = .millisecondsSince1970
        let receiptObject = try #require(JSONSerialization.jsonObject(
            with: receiptEncoder.encode(receipt)
        ) as? [String: Any])
        let requestData = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": [
                "name": "research_vault_submit_receipt",
                "arguments": ["receipt": receiptObject],
                "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]
            ]
        ])
        let submission = try #require(await handler.handleLine(requestData))
        #expect(String(decoding: submission, as: UTF8.self).contains("quarantined"))
        #expect(try await store.receipt(id: receipt.receiptID, authorization: authorization) == nil)
        #expect(try await gateway.quarantine().items.map(\.receiptID) == [receipt.receiptID])

        let duplicate = try #require(await handler.handleLine(requestData))
        #expect(String(decoding: duplicate, as: UTF8.self).contains("already_present"))
        #expect(try await gateway.quarantine().items.count == 1)

        let hiddenRead = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"throttle-research://receipt/15c13fb9-d9e1-4de1-bbf7-a329f21b8a4f"}}"#.utf8
        )))
        #expect(String(decoding: hiddenRead, as: UTF8.self).contains("Resource unavailable"))

        _ = try await gateway.review(.init(action: .approve, receiptIDs: [receipt.receiptID]))
        let listed = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#.utf8
        )))
        let listedText = String(decoding: listed, as: UTF8.self)
        #expect(listedText.contains("throttle-research://receipt/" + receipt.receiptID))
        #expect(listedText.contains("source%2Fone"))

        let sourceRead = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"throttle-research://source/15c13fb9-d9e1-4de1-bbf7-a329f21b8a4f/source%2Fone"}}"#.utf8
        )))
        let sourceText = String(decoding: sourceRead, as: UTF8.self)
        #expect(sourceText.contains("/evidence/source.txt"))
        #expect(sourceText.contains(String(repeating: "a", count: 64)))
        #expect(sourceText.contains("parent-agent") == false)
    }

    @Test("rejects unsupported per-request protocol metadata")
    func unsupportedModernVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-version-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x74, count: 32)
        )
        let handler = ResearchVaultMCPProtocolHandler(gateway: ResearchVaultGateway(
            store: store,
            authorization: VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        ))
        let response = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#.utf8
        )))
        #expect(String(decoding: response, as: UTF8.self).contains("-32022"))
    }

    @Test("reasoning MCP is read-only, bounded and provenance preserving")
    func reasoningReadOnlyTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-mcp-reasoning-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x77, count: 32)
        )
        let authorization = VaultAuthorization(
            projectKeys: ["throttle"], maximumSensitivity: .internal
        )
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let first = try Self.reasoningReceipt(
            id: "70000000-0000-4000-8000-000000000001",
            sourceID: "source-a"
        )
        let second = try Self.reasoningReceipt(
            id: "70000000-0000-4000-8000-000000000002",
            sourceID: "source-b"
        )
        _ = try await gateway.importReceipts([first, second])
        _ = try await gateway.refreshReasoningShadow(.init(relations: [.init(
            relation: .contradicts,
            subject: .init(receiptID: first.receiptID, findingIndex: 0),
            object: .init(receiptID: second.receiptID, findingIndex: 0)
        )]))
        let contradiction = try #require(try await gateway.reasoning(
            .init(kind: .contradictions)
        ).facts.first)
        let handler = ResearchVaultMCPProtocolHandler(gateway: gateway)

        let list = try #require(await handler.handleLine(Data(
            #"{"jsonrpc":"2.0","id":20,"method":"tools/list"}"#.utf8
        )))
        let listText = String(decoding: list, as: UTF8.self)
        #expect(listText.contains("research_vault_why"))
        #expect(listText.contains("research_vault_what_changed"))
        #expect(!listText.contains("promote_reasoning"))

        let whyRequest = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 21, "method": "tools/call",
            "params": [
                "name": "research_vault_why",
                "arguments": ["factID": contradiction.id, "limit": 8]
            ]
        ])
        let why = try #require(await handler.handleLine(whyRequest))
        let whyText = String(decoding: why, as: UTF8.self)
        #expect(whyText.contains(contradiction.id))
        #expect(whyText.contains(first.receiptID))
        #expect(whyText.contains("source-a"))
        #expect(!whyText.contains("isError\":true"))

        let proofURI = "throttle-research://proof/" + contradiction.id
        let resourceRequest = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 22, "method": "resources/read",
            "params": ["uri": proofURI]
        ])
        let resource = try #require(await handler.handleLine(resourceRequest))
        #expect(String(decoding: resource, as: UTF8.self).contains(contradiction.id))

        let hostile = "not-a-fact-secret-sentinel"
        let hostileRequest = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 23, "method": "tools/call",
            "params": [
                "name": "research_vault_why",
                "arguments": ["factID": hostile]
            ]
        ])
        let rejection = try #require(await handler.handleLine(hostileRequest))
        let rejectionText = String(decoding: rejection, as: UTF8.self)
        #expect(rejectionText.contains("Invalid fact ID"))
        #expect(!rejectionText.contains(hostile))
    }

    @Test("agent hooks are bounded, parent-linked, transcript-safe and restart-idempotent")
    func agentHookCandidates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-hook-" + UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        let transcriptSentinel = "raw-transcript-must-not-enter-receipt"
        try Data(transcriptSentinel.utf8).write(to: transcript)

        let missingParent = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SubagentStop", "session_id": "session-hook",
            "agent_id": "child", "project_key": "throttle"
        ])
        #expect(throws: ResearchVaultAgentHookError.missingParentAgent) {
            try ResearchVaultAgentHook().process(inputData: missingParent, inboxURL: inbox)
        }

        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SubagentStop", "session_id": "session-hook",
            "agent_id": "child", "parent_agent_id": "parent",
            "project_key": "throttle", "transcript_path": transcript.path,
            "occurred_at_ms": 1_787_832_300_000 as Int64
        ], options: [.sortedKeys])
        let first = try ResearchVaultAgentHook().process(inputData: input, inboxURL: inbox)
        #expect(first.status == "candidate_written")
        let second = try ResearchVaultAgentHook().process(inputData: input, inboxURL: inbox)
        #expect(second.receiptID == first.receiptID)
        #expect(second.status == "already_present")

        let receiptURL = inbox.appendingPathComponent(first.fileName)
        let receiptData = try Data(contentsOf: receiptURL)
        #expect(!String(decoding: receiptData, as: UTF8.self).contains(transcriptSentinel))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(ResearchReceipt.self, from: receiptData)
        #expect(receipt.parentAgentID == "parent")
        #expect(receipt.sources.map(\.kind) == [.transcript])
        #expect(receipt.findings.map(\.status) == [.hypothesis])

        let store = try SQLCipherReceiptStore(
            databaseURL: root.appendingPathComponent("vault.ccsql"),
            key: Data(repeating: 0x75, count: 32)
        )
        let authorization = VaultAuthorization(projectKeys: ["throttle"], maximumSensitivity: .internal)
        let gateway = ResearchVaultGateway(store: store, authorization: authorization)
        let imported = try await gateway.importReceiptInbox(root: inbox)
        #expect(imported.insertedReceipts == 1)
        #expect(try await store.receipt(id: receipt.receiptID, authorization: authorization) == nil)
        #expect(try await gateway.quarantine().items.map(\.receiptID) == [receipt.receiptID])
    }

    @Test("all three terminal hook events produce candidates")
    func terminalHookEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("research-vault-hook-events-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, event) in ["Stop", "SubagentStop", "SessionEnd"].enumerated() {
            var object: [String: Any] = [
                "hook_event_name": event, "session_id": "session-" + String(index),
                "agent_id": "agent-" + String(index), "project_key": "throttle",
                "occurred_at_ms": 1_787_832_400_000 + index
            ]
            if event == "SubagentStop" { object["parent_agent_id"] = "parent" }
            let input = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let result = try ResearchVaultAgentHook().process(inputData: input, inboxURL: root)
            #expect(result.status == "candidate_written")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(ResearchReceiptInbox.fileSuffix) }
        #expect(files.count == 3)
    }

    private static func reasoningReceipt(id: String, sourceID: String) throws -> ResearchReceipt {
        try ResearchReceipt.seal(
            receiptID: id,
            sessionID: "reasoning-mcp",
            agentID: "mcp-test",
            projectKey: "throttle",
            question: "Reasoning MCP fixture",
            findings: [.init(claim: sourceID, status: .verified, evidenceIDs: [sourceID])],
            sources: [.init(
                id: sourceID,
                kind: .file,
                locator: "evidence/" + sourceID + ".md",
                observedAt: Date(timeIntervalSince1970: 1_787_832_000),
                sha256: String(repeating: "f", count: 64)
            )],
            sensitivity: .internal,
            createdAt: Date(timeIntervalSince1970: 1_787_832_000)
        )
    }
}
