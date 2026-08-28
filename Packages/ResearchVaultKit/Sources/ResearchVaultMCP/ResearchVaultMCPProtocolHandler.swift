import Foundation
import ResearchVaultGateway

public actor ResearchVaultMCPProtocolHandler {
    private let gateway: ResearchVaultGateway
    private let encoder: JSONEncoder

    public init(gateway: ResearchVaultGateway) {
        self.gateway = gateway
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func handleLine(_ data: Data) async -> Data? {
        let request: RPCRequest
        do { request = try JSONDecoder().decode(RPCRequest.self, from: data) }
        catch { return encode(error: .null, code: -32700, message: "Parse error") }

        if request.method == "notifications/initialized" { return nil }
        let id = request.id ?? .null
        switch request.method {
        case "initialize":
            return encode(result: InitializeResult(
                protocolVersion: request.params?.protocolVersion ?? "2024-11-05",
                capabilities: .init(tools: .init()),
                serverInfo: .init(name: "research-vault", version: "0.1.0")
            ), id: id)
        case "ping":
            return encode(result: EmptyResult(), id: id)
        case "tools/list":
            return encode(result: ToolListResult(tools: Self.tools), id: id)
        case "tools/call":
            guard let name = request.params?.name else {
                return encode(error: id, code: -32602, message: "Missing tool name")
            }
            switch name {
            case "research_vault_search":
                guard let query = request.params?.arguments?.query,
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      query.utf8.count <= 4_096 else {
                    return encode(error: id, code: -32602, message: "Invalid query")
                }
                do {
                    let context = try await gateway.context(
                        query: query,
                        limit: request.params?.arguments?.limit ?? 8,
                        maximumCharacters: request.params?.arguments?.maximumCharacters ?? 12_000
                    )
                    let text = String(decoding: try encoder.encode(context), as: UTF8.self)
                    return encode(result: ToolResult(content: [.init(type: "text", text: text)], isError: false), id: id)
                } catch {
                    return encode(result: ToolResult(
                        content: [.init(type: "text", text: "Research Vault search unavailable.")],
                        isError: true
                    ), id: id)
                }
            case "research_vault_health":
                do {
                    let evidence = try await gateway.integrityEvidence()
                    let health = HealthPayload(
                        schemaVersion: evidence.schemaVersion,
                        cipherVersion: evidence.cipherVersion,
                        receiptCount: evidence.receiptCount,
                        documentCount: evidence.documentCount,
                        chunkCount: evidence.chunkCount,
                        quickCheckPassed: evidence.quickCheckPassed,
                        cipherIntegrityPassed: evidence.cipherIntegrityPassed,
                        foreignKeysPassed: evidence.foreignKeysPassed
                    )
                    let text = String(decoding: try encoder.encode(health), as: UTF8.self)
                    return encode(result: ToolResult(content: [.init(type: "text", text: text)], isError: false), id: id)
                } catch {
                    return encode(result: ToolResult(
                        content: [.init(type: "text", text: "Research Vault integrity unavailable.")],
                        isError: true
                    ), id: id)
                }
            default:
                return encode(error: id, code: -32602, message: "Unknown tool")
            }
        default:
            return encode(error: id, code: -32601, message: "Method not found")
        }
    }

    private func encode<Result: Encodable & Sendable>(result: Result, id: RPCID) -> Data? {
        try? encoder.encode(RPCResponse(id: id, result: result))
    }

    private func encode(error id: RPCID, code: Int, message: String) -> Data? {
        try? encoder.encode(RPCErrorResponse(id: id, error: .init(code: code, message: message)))
    }

    private static let tools = [
        MCPTool(
            name: "research_vault_search",
            description: "Search authorized local encrypted research. Returns bounded excerpts with document IDs, origins and SHA-256 citations.",
            inputSchema: .init(
                required: ["query"],
                properties: [
                    "query": .init(type: "string", minimum: nil, maximum: nil, minLength: 1, maxLength: 4_096),
                    "limit": .init(type: "integer", minimum: 1, maximum: 20, minLength: nil, maxLength: nil),
                    "maximumCharacters": .init(type: "integer", minimum: 256, maximum: 50_000, minLength: nil, maxLength: nil),
                ]
            )
        ),
        MCPTool(
            name: "research_vault_health",
            description: "Return secret-free SQLCipher integrity evidence for the authorized local vault.",
            inputSchema: .init(required: [], properties: [:])
        ),
    ]
}

private struct RPCRequest: Decodable, Sendable {
    let id: RPCID?
    let method: String
    let params: RPCParams?
}

private struct RPCParams: Decodable, Sendable {
    let protocolVersion: String?
    let name: String?
    let arguments: ToolArguments?
}

private struct ToolArguments: Decodable, Sendable {
    let query: String?
    let limit: Int?
    let maximumCharacters: Int?
}

private enum RPCID: Codable, Sendable {
    case integer(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
        else { self = .string(try value.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .integer(integer): try value.encode(integer)
        case let .string(string): try value.encode(string)
        case .null: try value.encodeNil()
        }
    }
}

private struct RPCResponse<Result: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: RPCID
    let result: Result
}

private struct RPCErrorResponse: Encodable, Sendable {
    struct Payload: Encodable, Sendable { let code: Int; let message: String }
    let jsonrpc = "2.0"
    let id: RPCID
    let error: Payload
}

private struct InitializeResult: Encodable, Sendable {
    struct Capabilities: Encodable, Sendable { let tools: EmptyResult }
    struct ServerInfo: Encodable, Sendable { let name: String; let version: String }
    let protocolVersion: String
    let capabilities: Capabilities
    let serverInfo: ServerInfo
}

private struct EmptyResult: Encodable, Sendable {}
private struct ToolListResult: Encodable, Sendable { let tools: [MCPTool] }
private struct MCPTool: Encodable, Sendable {
    let name: String
    let description: String
    let inputSchema: InputSchema
}
private struct InputSchema: Encodable, Sendable {
    let type = "object"
    let additionalProperties = false
    let required: [String]
    let properties: [String: PropertySchema]
}
private struct PropertySchema: Encodable, Sendable {
    let type: String
    let minimum: Int?
    let maximum: Int?
    let minLength: Int?
    let maxLength: Int?
}
private struct ToolResult: Encodable, Sendable {
    struct Content: Encodable, Sendable { let type: String; let text: String }
    let content: [Content]
    let isError: Bool
}
private struct HealthPayload: Encodable, Sendable {
    let schemaVersion: Int
    let cipherVersion: String
    let receiptCount: Int
    let documentCount: Int
    let chunkCount: Int
    let quickCheckPassed: Bool
    let cipherIntegrityPassed: Bool
    let foreignKeysPassed: Bool
}
