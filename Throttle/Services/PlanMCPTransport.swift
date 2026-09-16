import Foundation

/// JSON-RPC framing stays in the app adapter. The plan and knowledge router can
/// therefore be compiled and tested without the full MCP server process.
extension PlanMCPTools {
    static func routeCall(
        name: String,
        arguments: [String: Any]?,
        id: Any?
    ) {
        routeCall(
            name: name,
            arguments: arguments,
            onResult: {
                ThrottleMCPServer.respond(
                    id: id,
                    result: ThrottleMCPServer.textResult($0)
                )
            },
            onError: { ThrottleMCPServer.respond(id: id, error: $0) }
        )
    }
}
