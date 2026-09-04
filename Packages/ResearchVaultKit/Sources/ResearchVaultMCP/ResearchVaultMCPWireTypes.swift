import Foundation
import ResearchVaultModel

struct RPCRequest: Decodable {
    let id: RPCID?
    let method: String
    let params: RPCParams?
}

struct RPCParams: Decodable {
    enum CodingKeys: String, CodingKey {
        case protocolVersion, name, arguments, uri, cursor
        case metadata = "_meta"
    }
    let protocolVersion: String?
    let name: String?
    let arguments: ToolArguments?
    let uri: String?
    let cursor: String?
    let metadata: RequestMetadata?
}

struct RequestMetadata: Decodable {
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "io.modelcontextprotocol/protocolVersion"
    }
    let protocolVersion: String?
}

struct ToolArguments: Decodable {
    let query: String?
    let limit: Int?
    let maximumCharacters: Int?
    let receipt: ResearchReceipt?
    let factID: String?
}

enum RPCID: Codable {
    case integer(Int), string(String), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let integer = try? value.decode(Int.self) {
            self = .integer(integer)
        } else {
            self = try .string(value.decode(String.self))
        }
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

struct RPCResponse<Result: Encodable & Sendable>: Encodable {
    let jsonrpc = "2.0"
    let id: RPCID
    let result: Result
}

struct RPCErrorResponse: Encodable {
    let jsonrpc = "2.0"
    let id: RPCID
    let error: RPCErrorPayload
}

struct InitializeResult: Encodable {
    let protocolVersion: String
    let capabilities: InitializeCapabilities
    let serverInfo: ServerIdentity
}

struct DiscoverResult: Encodable {
    enum CodingKeys: String, CodingKey {
        case supportedVersions, capabilities, instructions, ttlMs, cacheScope
        case metadata = "_meta"
    }
    let supportedVersions: [String]
    let capabilities: DiscoverCapabilities
    let instructions: String
    let ttlMs: Int
    let cacheScope: String
    let metadata: DiscoverMetadata
}

struct EmptyResult: Encodable {}
struct ToolListResult: Encodable { let tools: [MCPTool] }
struct MCPTool: Encodable {
    let name: String
    let description: String
    let inputSchema: InputSchema
}

struct InputSchema: Encodable {
    let type = "object"
    let additionalProperties = false
    let required: [String]
    let properties: [String: PropertySchema]
}

struct PropertySchema: Encodable {
    let type: String
    let minimum: Int?
    let maximum: Int?
    let minLength: Int?
    let maxLength: Int?
}

struct ToolResult: Encodable {
    let content: [TextContent]
    let isError: Bool
}

struct SubmissionPayload: Encodable { let receiptID: String; let status: String }
struct HealthPayload: Encodable {
    let schemaVersion: Int
    let cipherVersion: String
    let receiptCount: Int
    let documentCount: Int
    let chunkCount: Int
    let quickCheckPassed: Bool
    let cipherIntegrityPassed: Bool
    let foreignKeysPassed: Bool
}

struct ResourceDescriptor: Encodable {
    let uri: String
    let name: String
    let title: String
    let mimeType: String
}

struct ResourceListResult: Encodable {
    let resources: [ResourceDescriptor]
    let nextCursor: String?
}

struct ResourceReadResult: Encodable { let contents: [ResourceContent] }
struct RPCErrorPayload: Encodable { let code: Int; let message: String }
struct InitializeCapabilities: Encodable { let tools: EmptyResult; let resources: EmptyResult }
struct ServerIdentity: Encodable { let name: String; let version: String }
struct CatalogCapability: Encodable { let listChanged: Bool }
struct DiscoverCapabilities: Encodable {
    let tools: CatalogCapability
    let resources: CatalogCapability
}

struct DiscoverMetadata: Encodable {
    enum CodingKeys: String, CodingKey {
        case serverInfo = "io.modelcontextprotocol/serverInfo"
    }
    let serverInfo: ServerIdentity
}

struct TextContent: Encodable { let type: String; let text: String }
struct ResourceContent: Encodable { let uri: String; let mimeType: String; let text: String }

enum MCPResourceURI {
    static func receipt(_ receiptID: String) -> String {
        "throttle-research://receipt/" + receiptID
    }

    static func source(receiptID: String, sourceID: String) -> String {
        "throttle-research://source/" + receiptID + "/" + encodePathComponent(sourceID)
    }

    static func proof(_ factID: String) -> String {
        "throttle-research://proof/" + factID
    }

    static func parseReceipt(_ uri: String) -> String? {
        let prefix = "throttle-research://receipt/"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        return UUID(uuidString: id) == nil ? nil : id.lowercased()
    }

    static func parseSource(_ uri: String) -> (receiptID: String, sourceID: String)? {
        let prefix = "throttle-research://source/"
        guard uri.hasPrefix(prefix) else { return nil }
        let parts = uri.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              UUID(uuidString: String(parts[0])) != nil,
              let sourceID = String(parts[1]).removingPercentEncoding,
              !sourceID.isEmpty else { return nil }
        return (String(parts[0]).lowercased(), sourceID)
    }

    static func parseProof(_ uri: String) -> String? {
        let prefix = "throttle-research://proof/"
        guard uri.hasPrefix(prefix) else { return nil }
        let factID = String(uri.dropFirst(prefix.count))
        return factID.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == nil
            ? nil : factID
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

enum MCPToolCatalog {
    static let tools = [search, health, submit, why, whatChanged]

    private static let search = MCPTool(
        name: "research_vault_search",
        description: "Search authorized local encrypted research with SHA-256 citations.",
        inputSchema: .init(required: ["query"], properties: [
            "query": .init(type: "string", minimum: nil, maximum: nil, minLength: 1, maxLength: 4_096),
            "limit": .init(type: "integer", minimum: 1, maximum: 20, minLength: nil, maxLength: nil),
            "maximumCharacters": .init(
                type: "integer", minimum: 256, maximum: 50_000, minLength: nil, maxLength: nil
            )
        ])
    )
    private static let health = MCPTool(
        name: "research_vault_health",
        description: "Return secret-free SQLCipher integrity evidence for the authorized local vault.",
        inputSchema: .init(required: [], properties: [:])
    )
    private static let submit = MCPTool(
        name: "research_vault_submit_receipt",
        description: "Submit one sealed receipt to owner-review quarantine; never approve it.",
        inputSchema: .init(required: ["receipt"], properties: [
            "receipt": .init(type: "object", minimum: nil, maximum: nil, minLength: nil, maxLength: nil)
        ])
    )
    private static let why = MCPTool(
        name: "research_vault_why",
        description: "Read a bounded proof for one authorized symbolic fact; never mutates facts or rules.",
        inputSchema: .init(required: ["factID"], properties: [
            "factID": .init(type: "string", minimum: nil, maximum: nil, minLength: 64, maxLength: 64),
            "limit": .init(type: "integer", minimum: 1, maximum: 256, minLength: nil, maxLength: nil),
        ])
    )
    private static let whatChanged = MCPTool(
        name: "research_vault_what_changed",
        description: "Read the latest bounded symbolic change set from the owner-approved shadow generation.",
        inputSchema: .init(required: [], properties: [
            "limit": .init(type: "integer", minimum: 1, maximum: 256, minLength: nil, maxLength: nil),
        ])
    )
}
