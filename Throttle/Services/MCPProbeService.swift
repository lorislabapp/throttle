import Foundation

/// Out-of-band MCP health prober (v3.0 Pillar 2, Stage-2 Step 1 — opt-in).
///
/// On an EXPLICIT user action, Throttle spawns a short-lived probe connection to a
/// configured stdio MCP server: `initialize` → `tools/list` → done, then kills it.
/// This yields real health (does it respond? how many tools? schema size →
/// token cost) WITHOUT rewriting `.mcp.json`, owning the server, or intercepting
/// Claude's traffic. It is NOT the Pattern-A proxy — just a functional probe.
///
/// Honesty (golden rule): the probe runs from Throttle's environment (via a login
/// shell so the user's profile/secrets load), which may differ from Claude Code's.
/// A non-response is reported as "couldn't probe from here", never as a hard
/// "server is broken". Spawning has side effects (the server briefly starts), so
/// this is user-triggered only.
struct MCPProbeResult: Sendable, Identifiable {
    enum Status: String, Sendable { case healthy, unresponsive, spawnError, notStdio }
    let id = UUID()
    let server: String
    let status: Status
    let toolCount: Int?
    let schemaBytes: Int?     // size of the tools/list JSON → ~token cost
    var schemaTokensEst: Int? { schemaBytes.map { TokenEstimate.fromBytes($0, kind: .dense) } }   // JSON tool schemas → dense ratio
}

enum MCPProbeService {

    /// Probe every configured stdio server in parallel (each with its own deadline).
    static func probeAll(timeout: TimeInterval = 7) async -> [MCPProbeResult] {
        let servers = stdioServers()
        guard !servers.isEmpty else { return [] }
        return await withTaskGroup(of: MCPProbeResult.self) { group in
            for s in servers { group.addTask { await probe(s, timeout: timeout) } }
            var out: [MCPProbeResult] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.server.localizedCaseInsensitiveCompare($1.server) == .orderedAscending }
        }
    }

    // MARK: - One probe

    private struct Server: Sendable { let name: String; let command: String; let args: [String]; let env: [String: String] }

    private static func probe(_ s: Server, timeout: TimeInterval) async -> MCPProbeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runProbe(s, timeout: timeout))
            }
        }
    }

    private static func runProbe(_ s: Server, timeout: TimeInterval) -> MCPProbeResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so the user's profile (PATH, bw-env secrets) loads, matching
        // how Claude Code's servers get their environment as closely as we can.
        let cmdline = ([s.command] + s.args).map(shellQuote).joined(separator: " ")
        p.arguments = ["-lc", "exec \(cmdline)"]
        p.environment = ProcessInfo.processInfo.environment.merging(s.env) { _, new in new }

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            return MCPProbeResult(server: s.name, status: .spawnError, toolCount: nil, schemaBytes: nil)
        }

        // Send the minimal handshake. We keep stdin open (closing it makes some
        // servers exit before answering); the watchdog reaps the process.
        let reqs = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"throttle-probe","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        inPipe.fileHandleForWriting.write(Data(reqs.utf8))
        // Close stdin: well-behaved stdio servers answer then exit on EOF (fast).
        // The watchdog below reaps any that keep running instead.
        try? inPipe.fileHandleForWriting.close()

        // Watchdog: terminate after the deadline so the blocking read returns.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1.5) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(data, server: s.name)
    }

    /// Find the `tools/list` (id 2) response among newline-delimited JSON-RPC.
    private static func parse(_ data: Data, server: String) -> MCPProbeResult {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return MCPProbeResult(server: server, status: .unresponsive, toolCount: nil, schemaBytes: nil)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            // id may be Int 2 or String "2"; match either.
            let isToolsList = (obj["id"] as? Int == 2) || (obj["id"] as? String == "2")
            guard isToolsList, let result = obj["result"] as? [String: Any] else { continue }
            let tools = result["tools"] as? [[String: Any]] ?? []
            let bytes = (try? JSONSerialization.data(withJSONObject: tools))?.count
            return MCPProbeResult(server: server, status: .healthy, toolCount: tools.count, schemaBytes: bytes)
        }
        // Got bytes but no parseable tools/list → responded but not cleanly.
        return MCPProbeResult(server: server, status: .unresponsive, toolCount: nil, schemaBytes: nil)
    }

    // MARK: - Config

    private static func stdioServers() -> [Server] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        var out: [Server] = []
        for (name, def) in servers {
            let d = def as? [String: Any] ?? [:]
            // Only stdio (has a `command`); http/sse probing is a separate path.
            guard let command = d["command"] as? String else { continue }
            let args = d["args"] as? [String] ?? []
            let env = d["env"] as? [String: String] ?? [:]
            out.append(Server(name: name, command: command, args: args, env: env))
        }
        return out
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
