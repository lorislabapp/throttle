import Foundation

/// Explicit, reversible installer for the project-local read firewall.
/// Nothing is written until the user accepts the notification/UI action.
enum ReadFirewallInstaller {
    static let serverName = "mcp-local-rag"

    static var definition: [String: Any] {
        [
            "command": "npx",
            "args": ["-y", "mcp-local-rag"],
            "env": [
                "EMBEDDING_MODEL": "Xenova/all-MiniLM-L6-v2",
                "VECTOR_STORE": "lancedb",
                "LANCEDB_PATH": ".throttle/lancedb",
            ],
        ]
    }

    @discardableResult
    static func install(projectPath: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: definition)
        try MCPConfigService.add(name: serverName, scope: .project(projectPath: projectPath),
                                 defJSON: data)
        return URL(fileURLWithPath: projectPath).appendingPathComponent(".mcp.json")
    }
}
