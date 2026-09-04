import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel

public actor ResearchVaultMCPProtocolHandler {
    public static let legacyProtocolVersion = "2024-11-05"
    public static let modernProtocolVersion = "2026-07-28"

    private let gateway: ResearchVaultGateway
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(gateway: ResearchVaultGateway) {
        self.gateway = gateway
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func handleLine(_ data: Data) async -> Data? {
        let request: RPCRequest
        do {
            request = try decoder.decode(RPCRequest.self, from: data)
        } catch {
            return encode(error: .null, code: -32700, message: "Parse error")
        }

        if request.method == "notifications/initialized" { return nil }
        let id = request.id ?? .null
        guard request.params?.metadata?.protocolVersion.map(Self.isSupportedModernVersion) ?? true else {
            return encode(error: id, code: -32022, message: "Unsupported protocol version")
        }
        return await dispatch(request, id: id)
    }

    private func dispatch(_ request: RPCRequest, id: RPCID) async -> Data? {
        switch request.method {
        case "initialize":
            return initialize(request, id: id)
        case "server/discover":
            return discover(id: id)
        case "ping":
            return encode(result: EmptyResult(), id: id)
        case "tools/list":
            return encode(result: ToolListResult(tools: MCPToolCatalog.tools), id: id)
        case "tools/call":
            return await handleToolCall(request, id: id)
        case "resources/list":
            return await listResources(request, id: id)
        case "resources/read":
            return await readResource(request, id: id)
        default:
            return encode(error: id, code: -32601, message: "Method not found")
        }
    }

    private static func isSupportedModernVersion(_ version: String) -> Bool {
        version == modernProtocolVersion
    }

    private func initialize(_ request: RPCRequest, id: RPCID) -> Data? {
        let requested = request.params?.protocolVersion
        guard requested == nil || requested == Self.legacyProtocolVersion else {
            return encode(error: id, code: -32022, message: "Unsupported protocol version")
        }
        return encode(result: InitializeResult(
            protocolVersion: Self.legacyProtocolVersion,
            capabilities: .init(tools: .init(), resources: .init()),
            serverInfo: .init(name: "research-vault", version: "0.3.0")
        ), id: id)
    }

    private func discover(id: RPCID) -> Data? {
        encode(result: DiscoverResult(
            supportedVersions: [Self.modernProtocolVersion, Self.legacyProtocolVersion],
            capabilities: .init(
                tools: .init(listChanged: false),
                resources: .init(listChanged: false)
            ),
            instructions: "Submitted receipts are quarantined. Evidence and reasoning proofs are read-only and owner-approved.",
            ttlMs: 60_000,
            cacheScope: "server",
            metadata: .init(serverInfo: .init(name: "research-vault", version: "0.3.0"))
        ), id: id)
    }

    private func handleToolCall(_ request: RPCRequest, id: RPCID) async -> Data? {
        guard let name = request.params?.name else {
            return encode(error: id, code: -32602, message: "Missing tool name")
        }
        switch name {
        case "research_vault_search":
            return await search(request.params?.arguments, id: id)
        case "research_vault_health":
            return await health(id: id)
        case "research_vault_submit_receipt":
            return await submit(request.params?.arguments?.receipt, id: id)
        case "research_vault_why":
            return await why(request.params?.arguments, id: id)
        case "research_vault_what_changed":
            return await whatChanged(request.params?.arguments, id: id)
        default:
            return encode(error: id, code: -32602, message: "Unknown tool")
        }
    }

    private func search(_ arguments: ToolArguments?, id: RPCID) async -> Data? {
        guard let query = arguments?.query,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 4_096 else {
            return encode(error: id, code: -32602, message: "Invalid query")
        }
        do {
            return toolJSON(try await gateway.context(
                query: query,
                limit: arguments?.limit ?? 8,
                maximumCharacters: arguments?.maximumCharacters ?? 12_000
            ), id: id)
        } catch {
            return toolFailure("Research Vault search unavailable.", id: id)
        }
    }

    private func health(id: RPCID) async -> Data? {
        do {
            let evidence = try await gateway.integrityEvidence()
            return toolJSON(HealthPayload(
                schemaVersion: evidence.schemaVersion,
                cipherVersion: evidence.cipherVersion,
                receiptCount: evidence.receiptCount,
                documentCount: evidence.documentCount,
                chunkCount: evidence.chunkCount,
                quickCheckPassed: evidence.quickCheckPassed,
                cipherIntegrityPassed: evidence.cipherIntegrityPassed,
                foreignKeysPassed: evidence.foreignKeysPassed
            ), id: id)
        } catch {
            return toolFailure("Research Vault integrity unavailable.", id: id)
        }
    }

    private func submit(_ receipt: ResearchReceipt?, id: RPCID) async -> Data? {
        guard let receipt else {
            return encode(error: id, code: -32602, message: "Invalid receipt")
        }
        do {
            let result = try await gateway.importReceiptsForReview([receipt])
            let status = result.insertedReceipts == 1 ? "quarantined" : "already_present"
            return toolJSON(SubmissionPayload(receiptID: receipt.receiptID, status: status), id: id)
        } catch {
            return toolFailure("Research receipt rejected.", id: id)
        }
    }

    private func why(_ arguments: ToolArguments?, id: RPCID) async -> Data? {
        guard let factID = arguments?.factID,
              factID.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            return encode(error: id, code: -32602, message: "Invalid fact ID")
        }
        do {
            return toolJSON(try await gateway.reasoning(ResearchVaultReasoningQuery(
                kind: .why,
                factID: factID,
                limit: arguments?.limit ?? 64
            )), id: id)
        } catch {
            return toolFailure("Reasoning proof unavailable.", id: id)
        }
    }

    private func whatChanged(_ arguments: ToolArguments?, id: RPCID) async -> Data? {
        do {
            return toolJSON(try await gateway.reasoning(ResearchVaultReasoningQuery(
                kind: .whatChanged,
                limit: arguments?.limit ?? 64
            )), id: id)
        } catch {
            return toolFailure("Reasoning change set unavailable.", id: id)
        }
    }

    private func listResources(_ request: RPCRequest, id: RPCID) async -> Data? {
        do {
            let receipts = try await gateway.approvedReceipts()
            var resources: [ResourceDescriptor] = []
            for receipt in receipts {
                resources.append(ResourceDescriptor(
                    uri: MCPResourceURI.receipt(receipt.receiptID),
                    name: "Receipt " + receipt.receiptID,
                    title: String(receipt.question.prefix(160)),
                    mimeType: "application/json"
                ))
                for source in receipt.sources.sorted(by: { $0.id < $1.id }) {
                    resources.append(ResourceDescriptor(
                        uri: MCPResourceURI.source(receiptID: receipt.receiptID, sourceID: source.id),
                        name: "Source " + source.id,
                        title: String(source.locator.prefix(160)),
                        mimeType: "application/json"
                    ))
                }
            }
            let start = request.params?.cursor.flatMap(Int.init) ?? 0
            guard start >= 0, start <= resources.count else {
                return encode(error: id, code: -32602, message: "Invalid cursor")
            }
            let page = Array(resources.dropFirst(start).prefix(100))
            let next = start + page.count < resources.count ? String(start + page.count) : nil
            return encode(result: ResourceListResult(resources: page, nextCursor: next), id: id)
        } catch {
            return encode(error: id, code: -32001, message: "Resources unavailable")
        }
    }

    private func readResource(_ request: RPCRequest, id: RPCID) async -> Data? {
        guard let uri = request.params?.uri else {
            return encode(error: id, code: -32602, message: "Missing resource URI")
        }
        do {
            if let receiptID = MCPResourceURI.parseReceipt(uri) {
                return try resourceJSON(await gateway.approvedReceipt(id: receiptID), uri: uri, id: id)
            }
            if let source = MCPResourceURI.parseSource(uri) {
                return try resourceJSON(await gateway.approvedSource(
                    receiptID: source.receiptID,
                    sourceID: source.sourceID
                ), uri: uri, id: id)
            }
            if let factID = MCPResourceURI.parseProof(uri) {
                return try resourceJSON(await gateway.reasoning(
                    ResearchVaultReasoningQuery(kind: .why, factID: factID, limit: 100)
                ), uri: uri, id: id)
            }
            return encode(error: id, code: -32602, message: "Invalid resource URI")
        } catch {
            return encode(error: id, code: -32002, message: "Resource unavailable")
        }
    }

    private func toolJSON<Value: Encodable & Sendable>(_ value: Value, id: RPCID) -> Data? {
        guard let data = try? encoder.encode(value) else { return toolFailure("Encoding unavailable.", id: id) }
        return encode(result: ToolResult(
            content: [.init(type: "text", text: String(data: data, encoding: .utf8) ?? "")],
            isError: false
        ), id: id)
    }

    private func resourceJSON<Value: Encodable & Sendable>(_ value: Value, uri: String, id: RPCID) -> Data? {
        guard let data = try? encoder.encode(value) else {
            return encode(error: id, code: -32603, message: "Resource encoding unavailable")
        }
        return encode(result: ResourceReadResult(contents: [.init(
            uri: uri,
            mimeType: "application/json",
            text: String(data: data, encoding: .utf8) ?? ""
        )]), id: id)
    }

    private func toolFailure(_ message: String, id: RPCID) -> Data? {
        encode(result: ToolResult(content: [.init(type: "text", text: message)], isError: true), id: id)
    }

    private func encode<Result: Encodable & Sendable>(result: Result, id: RPCID) -> Data? {
        try? encoder.encode(RPCResponse(id: id, result: result))
    }

    private func encode(error id: RPCID, code: Int, message: String) -> Data? {
        try? encoder.encode(RPCErrorResponse(id: id, error: .init(code: code, message: message)))
    }

}
