import Foundation

/// Persists the last MCP-health probe to the App Group so the `--mcp-server` CLI
/// process (a separate launch of the same binary) can answer get_mcp_health_status.
/// The app writes after each probe; the server reads + reports the probe age so a
/// stale reading is never passed off as live (golden rule).
struct MCPHealthRecord: Codable, Sendable {
    let name: String
    let status: String        // ok | slow | down | remote | unknown
    let latencyMs: Int?
    let toolCount: Int?
}

struct MCPHealthSnapshot: Codable, Sendable {
    let servers: [MCPHealthRecord]
    let probedAt: Date
}

enum ThrottleMCPHealthStore {
    private static let key = "ThrottleMCPHealthV1"
    private static var defaults: UserDefaults { UserDefaults(suiteName: ThrottleAppGroupID) ?? .standard }

    static func write(_ healths: [MCPHealth]) {
        let recs = healths.map {
            MCPHealthRecord(name: $0.name, status: statusString($0.status),
                            latencyMs: $0.latencyMs, toolCount: $0.toolCount)
        }
        let snap = MCPHealthSnapshot(servers: recs, probedAt: Date())
        defaults.set(try? JSONEncoder().encode(snap), forKey: key)
    }

    static func read() -> MCPHealthSnapshot? {
        guard let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(MCPHealthSnapshot.self, from: data) else { return nil }
        return snap
    }

    static func statusString(_ s: MCPHealth.Status) -> String {
        switch s {
        case .ok: return "ok"; case .slow: return "slow"; case .down: return "down"
        case .remote: return "remote"; case .unknown: return "unknown"
        }
    }
}
