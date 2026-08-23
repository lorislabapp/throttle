import Foundation

/// Out-of-band MCP prober (v3.0 Pillar 2, Stage-2 Step 1 — opt-in).
///
/// On an EXPLICIT user action, Throttle opens a short-lived MCP connection to each
/// configured server — `initialize` → `tools/list` → done — and measures the exact
/// byte size of the tool list. That JSON is what gets injected into the model's
/// context on every turn of every session where the server is enabled, so it is a
/// real recurring cost, not a curiosity.
///
/// Both transports are covered, because a gap in coverage reads as "free":
///   • **stdio** — spawn the command through a login shell, speak JSON-RPC over
///     stdin/stdout, kill it.
///   • **http** — POST the same JSON-RPC to the server's URL (Streamable HTTP),
///     honouring the session id it hands back. A remote server spawns no process
///     on the Mac but still bills its tool list into every prompt.
/// Legacy `sse` is reported as `unsupportedTransport` rather than silently
/// skipped — an unmeasured server must never look like a cheap one.
///
/// All three config scopes are read (user, project-local, project `.mcp.json`) via
/// `MCPConfigService`, deduplicated by server name: the same server declared in
/// twelve projects is one server and gets probed once.
///
/// Honesty (golden rule): the probe runs from Throttle's environment (via a login
/// shell so the user's profile/secrets load), which may differ from Claude Code's.
/// A non-response is reported as "couldn't probe from here", never as a hard
/// "server is broken". Probing has side effects — a stdio server briefly starts, a
/// remote one sees a real authenticated request — so this is user-triggered only.
struct MCPProbeResult: Sendable, Identifiable {
    enum Status: String, Sendable {
        case healthy
        case unresponsive           // answered nothing usable
        case spawnError             // stdio: couldn't start
        case authRequired           // http: 401/403 — up, but won't show its tools
        case unsupportedTransport   // sse, or a def we can't speak
    }
    let id = UUID()
    let server: String
    let remote: Bool
    let status: Status
    let toolCount: Int?
    /// Full `tools/list` JSON — the CEILING: what context costs when the client
    /// sends complete tool schemas.
    let schemaBytes: Int?
    /// Just the `mcp__<server>__<tool>` names — the FLOOR: what context costs when
    /// the client defers schemas and lists names only, as Claude Code does. The
    /// gap is large (measured 2026-08-22: hostinger-mcp, 201 tools → 9.8 KB of
    /// names vs 131 KB of schemas), so reporting one number alone misleads.
    let nameBytes: Int?
    var schemaTokensEst: Int? { schemaBytes.map { TokenEstimate.fromBytes($0, kind: .dense) } }   // JSON tool schemas → dense ratio
    var nameTokensEst: Int? { nameBytes.map { TokenEstimate.fromBytes($0, kind: .dense) } }
}

enum MCPProbeService {

    /// Probe every configured, enabled server in parallel (each with its own
    /// deadline) and persist the measurements for the advisor.
    static func probeAll(timeout: TimeInterval = 7) async -> [MCPProbeResult] {
        let servers = configuredServers()
        guard !servers.isEmpty else { return [] }
        return await withTaskGroup(of: MCPProbeResult.self) { group in
            for s in servers { group.addTask { await probe(s, timeout: timeout) } }
            var out: [MCPProbeResult] = []
            for await r in group { out.append(r) }
            // Persist the schema weights: the advisor needs them later, and it must
            // not spawn servers or hit the network of its own accord to get them.
            MCPSchemaCache.record(out)
            return out.sorted { $0.server.localizedCaseInsensitiveCompare($1.server) == .orderedAscending }
        }
    }

    // MARK: - Model

    private enum Target: Sendable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: URL, headers: [String: String])
        case unsupported
    }
    private struct Server: Sendable {
        let name: String
        let target: Target
        var remote: Bool { if case .http = target { return true }; return false }
    }

    private static func probe(_ s: Server, timeout: TimeInterval) async -> MCPProbeResult {
        switch s.target {
        case .unsupported:
            return MCPProbeResult(server: s.name, remote: false, status: .unsupportedTransport,
                                  toolCount: nil, schemaBytes: nil, nameBytes: nil)
        case .stdio(let command, let args, let env):
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runStdioProbe(name: s.name, command: command, args: args,
                                                         env: env, timeout: timeout))
                }
            }
        case .http(let url, let headers):
            return await runHTTPProbe(name: s.name, url: url, headers: headers, timeout: timeout)
        }
    }

    // MARK: - JSON-RPC payloads (shared by both transports)

    private static let initializeReq =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"throttle-probe","version":"1.0"}}}"#
    private static let initializedNote =
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    private static let toolsListReq =
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

    // MARK: - stdio probe

    private static func runStdioProbe(name: String, command: String, args: [String],
                                      env: [String: String], timeout: TimeInterval) -> MCPProbeResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shell so the user's profile (PATH, bw-env secrets) loads, matching
        // how Claude Code's servers get their environment as closely as we can.
        let cmdline = ([command] + args).map(shellQuote).joined(separator: " ")
        p.arguments = ["-lc", "exec \(cmdline)"]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            return MCPProbeResult(server: name, remote: false, status: .spawnError,
                                  toolCount: nil, schemaBytes: nil, nameBytes: nil)
        }

        let reqs = [initializeReq, initializedNote, toolsListReq].joined(separator: "\n") + "\n"
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
        return parse(data, server: name, remote: false)
    }

    // MARK: - http probe (Streamable HTTP)

    /// `initialize` → carry the session id → `tools/list`. Unlike the passive HEAD
    /// in `MCPHealthService`, this is a real request that will trigger the server's
    /// auth; that is why it only runs on an explicit user action.
    private static func runHTTPProbe(name: String, url: URL, headers: [String: String],
                                     timeout: TimeInterval) async -> MCPProbeResult {
        func fail(_ s: MCPProbeResult.Status) -> MCPProbeResult {
            MCPProbeResult(server: name, remote: true, status: s, toolCount: nil, schemaBytes: nil, nameBytes: nil)
        }

        guard let handshake = await rpc(url: url, headers: headers, session: nil,
                                        body: initializeReq, expectID: nil, timeout: timeout)
        else { return fail(.unresponsive) }
        if handshake.status == 401 || handshake.status == 403 { return fail(.authRequired) }
        guard (200..<300).contains(handshake.status) else { return fail(.unresponsive) }

        // The spec puts the session id in a response header; servers that don't use
        // one simply omit it and we send nothing.
        let session = handshake.session

        _ = await rpc(url: url, headers: headers, session: session,
                      body: initializedNote, expectID: nil, timeout: timeout)

        guard let list = await rpc(url: url, headers: headers, session: session,
                                   body: toolsListReq, expectID: 2, timeout: timeout)
        else { return fail(.unresponsive) }
        if list.status == 401 || list.status == 403 { return fail(.authRequired) }
        guard (200..<300).contains(list.status), let result = list.payload?["result"] as? [String: Any]
        else { return fail(.unresponsive) }
        let tools = result["tools"] as? [[String: Any]] ?? []
        return measured(tools, server: name, remote: true)
    }

    // Not `Sendable`: it never leaves this file's nonisolated async path — only the
    // final `MCPProbeResult` crosses the task-group boundary.
    private struct HTTPStep { let status: Int; let session: String?; let payload: [String: Any]? }

    /// One JSON-RPC POST. The body is consumed as a **stream** and abandoned the
    /// moment the awaited id arrives: a Streamable HTTP server is supposed to close
    /// its SSE stream after answering, but one that holds it open would otherwise
    /// stall the probe until the deadline and be misreported as unresponsive.
    /// With `expectID: nil` the body is never read at all (handshake / notification).
    private static func rpc(url: URL, headers: [String: String], session: String?, body: String,
                            expectID: Int?, timeout: TimeInterval) async -> HTTPStep? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Streamable HTTP servers may answer with either plain JSON or an SSE
        // stream; `jsonRPC(from:)` handles both, so accept both.
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = Data(body.utf8)

        guard let (stream, resp) = try? await URLSession.shared.bytes(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard let expectID, (200..<300).contains(http.statusCode) else {
            return HTTPStep(status: http.statusCode, session: sid, payload: nil)
        }
        // Leaving this loop deallocates the stream, which cancels the transfer.
        do {
            for try await line in stream.lines {
                guard let obj = jsonRPC(from: line[...]), matchesID(obj, expectID) else { continue }
                return HTTPStep(status: http.statusCode, session: sid, payload: obj)
            }
        } catch { /* stream cut short — fall through to "no payload" */ }
        return HTTPStep(status: http.statusCode, session: sid, payload: nil)
    }

    // MARK: - Response parsing (shared)

    /// Decode one line of a JSON-RPC response. Handles both the newline-delimited
    /// JSON of stdio and the SSE framing (`data: {...}`) of Streamable HTTP, so a
    /// single parser serves both transports.
    private static func jsonRPC(from line: Substring) -> [String: Any]? {
        var body = line
        if body.hasPrefix("data:") { body = body.dropFirst(5) }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
    }

    /// Turn a tools array into both weights. Names are billed as the client writes
    /// them — `mcp__<server>__<tool>`, one per line — so the prefix and separator
    /// are part of the cost.
    private static func measured(_ tools: [[String: Any]], server: String, remote: Bool) -> MCPProbeResult {
        let schema = (try? JSONSerialization.data(withJSONObject: tools))?.count
        let names = tools.reduce(0) { acc, t in
            acc + ((t["name"] as? String).map { "mcp__\(server)__\($0)\n".utf8.count } ?? 0)
        }
        return MCPProbeResult(server: server, remote: remote, status: .healthy,
                              toolCount: tools.count, schemaBytes: schema, nameBytes: names)
    }

    /// id may come back as Int 2 or String "2"; match either.
    private static func matchesID(_ obj: [String: Any], _ id: Int) -> Bool {
        (obj["id"] as? Int == id) || (obj["id"] as? String == String(id))
    }

    /// Find the `tools/list` (id 2) response in a whole stdio transcript.
    private static func parse(_ data: Data, server: String, remote: Bool) -> MCPProbeResult {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return MCPProbeResult(server: server, remote: remote, status: .unresponsive,
                                  toolCount: nil, schemaBytes: nil, nameBytes: nil)
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = jsonRPC(from: line), matchesID(obj, 2),
                  let result = obj["result"] as? [String: Any] else { continue }
            let tools = result["tools"] as? [[String: Any]] ?? []
            return measured(tools, server: server, remote: remote)
        }
        // Got bytes but no parseable tools/list → responded but not cleanly.
        return MCPProbeResult(server: server, remote: remote, status: .unresponsive,
                              toolCount: nil, schemaBytes: nil, nameBytes: nil)
    }

    // MARK: - Config

    /// Every enabled server across all three scopes, one entry per NAME. Claude
    /// Code addresses tools as `mcp__<name>__…`, so the name is the identity that
    /// matters; a server declared in a dozen projects is probed once.
    private static func configuredServers() -> [Server] {
        var byName: [String: Server] = [:]
        var fromUserScope: Set<String> = []
        // A project `.mcp.json` is committed INTO a repository, so its `command`
        // is written by whoever wrote the repo — and probing means running it
        // through a login shell, with the user's PATH and whatever `.zshrc`
        // exports. Claude Code gates that behind an explicit per-project
        // approval; Throttle did not, so cloning a repo and opening it once was
        // enough to arm an execution the user never consented to.
        for entry in MCPConfigService.list()
        where !entry.disabled && MCPConfigService.isApprovedForExecution(entry) {
            let isUser = entry.scope == .user
            // Same name in several scopes: the global (user) definition is the one
            // that applies everywhere, so it wins over a per-project variant.
            if byName[entry.name] != nil, !(isUser && !fromUserScope.contains(entry.name)) { continue }
            guard let def = try? JSONSerialization.jsonObject(with: entry.rawData) as? [String: Any] else { continue }
            byName[entry.name] = Server(name: entry.name, target: target(from: def))
            if isUser { fromUserScope.insert(entry.name) }
        }
        return Array(byName.values)
    }

    private static func target(from def: [String: Any]) -> Target {
        let type = (def["type"] as? String)?.lowercased()
        if let command = def["command"] as? String, type != "http", type != "sse" {
            return .stdio(command: command,
                          args: def["args"] as? [String] ?? [],
                          env: def["env"] as? [String: String] ?? [:])
        }
        if type == "sse" { return .unsupported }   // legacy transport — say so, don't skip
        if let raw = def["url"] as? String, let url = URL(string: raw) {
            return .http(url: url, headers: def["headers"] as? [String: String] ?? [:])
        }
        return .unsupported
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
