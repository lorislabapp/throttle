import Foundation

/// Real MCP health for the cockpit — a `list_tools` handshake per server.
///
/// Reliability comes from spawning stdio servers through the user's LOGIN shell
/// (`zsh -lc`), so `.zshrc` loads the same PATH *and* secrets (e.g. Bitwarden
/// env) that Claude Code itself runs with — avoiding the false "down" you'd get
/// from a bare spawn. Probing is on-demand (never on a timer): a healthy probe
/// still launches the server briefly, so we don't hammer it.
///
/// Remote (URL) servers are only HEAD-reachability checked — never spawned —
/// so OAuth servers can't trigger an auth flow.
struct MCPServerConfig: Sendable, Identifiable {
    enum Transport: Sendable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
    }
    let name: String
    let transport: Transport
    var id: String { name }
}

struct MCPHealth: Sendable, Identifiable {
    enum Status: Sendable { case ok, slow, down, remote, unknown }
    let name: String
    let status: Status
    let latencyMs: Int?
    let toolCount: Int?
    var id: String { name }

    static func unknown(_ name: String) -> MCPHealth {
        MCPHealth(name: name, status: .unknown, latencyMs: nil, toolCount: nil)
    }
}

enum MCPHealthService {
    static let probeTimeout: TimeInterval = 25   // MCP cold-start (npx/python) is often slow

    // MARK: Config

    static func servers() -> [MCPServerConfig] {
        var out: [String: MCPServerConfig] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        let urls = [home.appendingPathComponent(".claude.json"),
                    home.appendingPathComponent(".claude/settings.json")]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mcps = obj["mcpServers"] as? [String: Any] else { continue }
            for (name, raw) in mcps where out[name] == nil {
                guard let cfg = raw as? [String: Any] else { continue }
                if let urlStr = cfg["url"] as? String, let u = URL(string: urlStr) {
                    let headers = (cfg["headers"] as? [String: String]) ?? [:]
                    out[name] = MCPServerConfig(name: name, transport: .http(url: u, headers: headers))
                } else if let command = cfg["command"] as? String {
                    let args = (cfg["args"] as? [String]) ?? []
                    let env = (cfg["env"] as? [String: String]) ?? [:]
                    out[name] = MCPServerConfig(name: name, transport: .stdio(command: command, args: args, env: env))
                }
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }

    // MARK: Probe

    static func probeAll() async -> [MCPHealth] {
        let configs = servers()
        guard !configs.isEmpty else { return [] }
        // Batch (max 4 concurrent) — avoids pipe/IO contention that starved reads.
        var results: [MCPHealth] = []
        var i = 0
        while i < configs.count {
            let chunk = Array(configs[i ..< min(i + 4, configs.count)])
            let batch = await withTaskGroup(of: MCPHealth.self) { group in
                for c in chunk { group.addTask { await probe(c) } }
                var r: [MCPHealth] = []
                for await x in group { r.append(x) }
                return r
            }
            results.append(contentsOf: batch)
            i += 4
        }
        return results.sorted { $0.name < $1.name }
    }

    static func probe(_ config: MCPServerConfig) async -> MCPHealth {
        switch config.transport {
        case .http(let url, _):       return await probeHTTP(name: config.name, url: url)
        case .stdio(let cmd, let a, let e): return await probeStdio(name: config.name, command: cmd, args: a, env: e)
        }
    }

    // MARK: stdio

    private static func probeStdio(name: String, command: String, args: [String], env: [String: String]) async -> MCPHealth {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell → .zshrc (PATH + secrets), then exec the server with its env.
        let envPrefix = env.map { "\(shellQuote($0.key))=\(shellQuote($0.value))" }.joined(separator: " ")
        let cmdLine = ([command] + args).map(shellQuote).joined(separator: " ")
        let line = "exec env \(envPrefix) \(cmdLine)"
        proc.arguments = ["-lc", line]

        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return MCPHealth(name: name, status: .down, latencyMs: nil, toolCount: nil) }

        let initReq = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Throttle","version":"1.0"}}}"#
        let initd = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let listReq = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let start = Date()
        try? inPipe.fileHandleForWriting.write(contentsOf: Data((initReq + "\n" + initd + "\n" + listReq + "\n").utf8))

        let count = await readToolsList(outPipe.fileHandleForReading, timeout: probeTimeout)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if proc.isRunning { proc.terminate() }
        try? inPipe.fileHandleForWriting.close()

        guard let count, count >= 0 else {
            return MCPHealth(name: name, status: .down, latencyMs: count == -1 ? ms : nil, toolCount: nil)
        }
        let status: MCPHealth.Status = ms > 2500 ? .slow : .ok
        return MCPHealth(name: name, status: status, latencyMs: ms, toolCount: count)
    }

    /// Reads newline-delimited JSON-RPC, resolving with the tool count of the
    /// `id:2` response. Returns -1 on an error response, nil on EOF/timeout.
    /// Uses a chunked POSIX read on a detached thread (the previous
    /// `bytes.lines` byte-at-a-time reader serialized under concurrency); races
    /// it against a timeout, and the caller terminates the process after.
    private static func readToolsList(_ fh: FileHandle, timeout: TimeInterval) async -> Int? {
        let fd = fh.fileDescriptor
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                await Task.detached(priority: .utility) {
                    var buf = [UInt8]()
                    var tmp = [UInt8](repeating: 0, count: 1 << 16)
                    while true {
                        let n = tmp.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                        if n <= 0 { return Int?.none }                 // EOF / error
                        buf.append(contentsOf: tmp[0 ..< n])
                        while let nl = buf.firstIndex(of: 0x0A) {
                            let line = Data(buf[buf.startIndex ..< nl])
                            buf.removeSubrange(buf.startIndex ... nl)
                            if let r = toolCount(fromLine: line) { return r }
                        }
                    }
                }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first: Int? = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Parse one JSON line; return the tool count if it's the id:2 result,
    /// -1 if it's the id:2 error, nil otherwise (keep reading).
    private static func toolCount(fromLine line: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let id = (obj["id"] as? Int) ?? Int((obj["id"] as? String) ?? "")
        guard id == 2 else { return nil }
        if let result = obj["result"] as? [String: Any], let tools = result["tools"] as? [Any] {
            return tools.count
        }
        if obj["error"] != nil { return -1 }
        return nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: http (reachability only — never spawned, no auth triggered)

    private static func probeHTTP(name: String, url: URL) async -> MCPHealth {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 2xx/3xx, or 401/403 (up but needs auth) = reachable.
            let reachable = (200..<400).contains(code) || code == 401 || code == 403
            return MCPHealth(name: name, status: reachable ? .remote : .down, latencyMs: ms, toolCount: nil)
        } catch {
            return MCPHealth(name: name, status: .down, latencyMs: nil, toolCount: nil)
        }
    }
}
