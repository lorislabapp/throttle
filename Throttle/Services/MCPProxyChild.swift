import Foundation

/// The downstream half of the Pattern-A MCP proxy: a JSON-RPC stdio CLIENT that
/// OWNS one fragile MCP server as a child process. Unlike the Pattern-B wrapper
/// (raw byte passthrough), this speaks JSON-RPC itself so it can:
///   • run the initialize handshake + cache the server's tools/list ONCE;
///   • route tools/call to the child, correlating responses by id;
///   • on a child death / hang, KILL + respawn + re-initialize, then RE-VERIFY the
///     tools list is byte-identical to the cached one — the guarantee that the
///     upstream prefix (what Claude Code cached) never changes, so a downstream
///     crash costs zero cache rebuild. That byte-stable tools list is the whole
///     point of Pattern-A vs a naive restart.
///
/// This is the testable core; the HTTP-Streamable front that Claude Code connects
/// to is layered on top separately (it needs live testing against CC's MCP client).
final class MCPProxyChild: @unchecked Sendable {
    let command: String
    let args: [String]

    private let q = DispatchQueue(label: "throttle.mcpproxy.child")
    private var child: Process?
    private var childIn: FileHandle?
    private var inPipe: Pipe?, outPipe: Pipe?, errPipe: Pipe?
    private var buffer = Data()
    private var pending: [String: (([String: Any]?) -> Void)] = [:]
    private var idSeq = 0

    private(set) var cachedTools: [[String: Any]] = []
    private(set) var lastError: String?

    init(command: String, args: [String]) { self.command = command; self.args = args }

    // MARK: - Lifecycle

    /// Spawn, handshake, and cache tools/list. Returns false on failure.
    @discardableResult
    func startAndInitialize(timeout: TimeInterval = 8) -> Bool {
        q.sync { spawn() }
        guard child != nil else { lastError = "spawn failed"; return false }
        guard let initResp = rawRequest(method: "initialize", params: initParams(), timeout: timeout),
              initResp["result"] != nil else { lastError = "initialize failed"; return false }
        notify(method: "notifications/initialized")
        guard let tools = fetchTools(timeout: timeout) else { lastError = "tools/list failed"; return false }
        cachedTools = tools
        return true
    }

    /// Route a tools/call to the child. On a dead/hung child, respawn (preserving
    /// the cached tools) and retry once. Returns the JSON-RPC `result` object.
    func callTool(name: String, arguments: [String: Any], timeout: TimeInterval = 60) -> [String: Any]? {
        let params: [String: Any] = ["name": name, "arguments": arguments]
        if let r = rawRequest(method: "tools/call", params: params, timeout: timeout),
           let result = r["result"] as? [String: Any] { return result }
        // Child likely died/hung — respawn invisibly + retry once.
        guard respawnAndReverify(timeout: timeout) else { return nil }
        return rawRequest(method: "tools/call", params: params, timeout: timeout)?["result"] as? [String: Any]
    }

    /// Kill + respawn + re-handshake, and confirm the tools list is unchanged
    /// (byte-identical). Returns false if the new tools list drifted (prefix would
    /// bust — the caller should surface that rather than silently continue).
    @discardableResult
    func respawnAndReverify(timeout: TimeInterval = 8) -> Bool {
        q.sync {
            child?.terminate()
            child = nil
        }
        q.sync { spawn() }
        guard child != nil,
              let r = rawRequest(method: "initialize", params: initParams(), timeout: timeout), r["result"] != nil
        else { lastError = "respawn initialize failed"; return false }
        notify(method: "notifications/initialized")
        guard let tools = fetchTools(timeout: timeout) else { lastError = "respawn tools/list failed"; return false }
        if !toolsIdentical(tools, cachedTools) {
            lastError = "tools list drifted after respawn — prefix would bust"
            return false
        }
        return true
    }

    func shutdown() { monitor?.cancel(); monitor = nil; q.sync { child?.terminate(); child = nil } }

    // MARK: - Proactive health monitor

    private let monQ = DispatchQueue(label: "throttle.mcpproxy.mon")
    private var monitor: DispatchSourceTimer?

    /// Ping the downstream periodically; a missed ping means it hung/zombied, so we
    /// respawn it BEFORE the next real tools/call fails — proactive sub-second MTTR
    /// instead of failing one agent call first. Runs on its own queue so the ping's
    /// blocking rawRequest doesn't deadlock the child's serial queue.
    func startHealthMonitor(interval: TimeInterval = 15) {
        let t = DispatchSource.makeTimerSource(queue: monQ)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.rawRequest(method: "ping", params: [:], timeout: 5) == nil {
                FileHandle.standardError.write(Data("throttle --mcp-proxy: downstream unresponsive → respawning\n".utf8))
                _ = self.respawnAndReverify()
            }
        }
        t.resume()
        monitor = t
    }

    // MARK: - JSON-RPC

    private func fetchTools(timeout: TimeInterval) -> [[String: Any]]? {
        guard let r = rawRequest(method: "tools/list", params: [:], timeout: timeout),
              let result = r["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return nil }
        return tools
    }

    private func initParams() -> [String: Any] {
        ["protocolVersion": "2024-11-05",
         "capabilities": [:] as [String: Any],
         "clientInfo": ["name": "throttle-proxy", "version": "1.0.0"]]
    }

    /// Send a request + block until the matching response or timeout.
    private func rawRequest(method: String, params: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let id = q.sync { () -> String in idSeq += 1; return "p\(idSeq)" }
        let sem = DispatchSemaphore(value: 0)
        var response: [String: Any]?
        q.sync { pending[id] = { resp in response = resp; sem.signal() } }
        let line = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])) ?? Data()
        q.async { try? self.childIn?.write(contentsOf: line); try? self.childIn?.write(contentsOf: Data("\n".utf8)) }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            q.sync { pending[id] = nil }
            return nil
        }
        return response
    }

    private func notify(method: String) {
        let line = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])) ?? Data()
        q.async { try? self.childIn?.write(contentsOf: line); try? self.childIn?.write(contentsOf: Data("\n".utf8)) }
    }

    private func handleStdout(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let id = obj["id"] as? String, let handler = pending[id] {
                pending[id] = nil
                handler(obj)
            }
        }
    }

    private func toolsIdentical(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        func canon(_ t: [[String: Any]]) -> Data? {
            // Sort by tool name + serialize with sorted keys → byte-stable comparison.
            let sorted = t.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            return try? JSONSerialization.data(withJSONObject: sorted, options: [.sortedKeys])
        }
        return canon(a) == canon(b)
    }

    // MARK: - Spawn (call inside q)

    private func spawn() {
        let p = Process()
        p.executableURL = command.contains("/") ? URL(fileURLWithPath: command) : URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = command.contains("/") ? args : ([command] + args)
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        inPipe = inP; outPipe = outP; errPipe = errP
        p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
        errP.fileHandleForReading.readabilityHandler = { _ = $0.availableData }   // drain
        outP.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.q.async { self.handleStdout(d) }
        }
        do { try p.run() } catch { lastError = "spawn: \(error)"; return }
        child = p
        childIn = inP.fileHandleForWriting
    }
}
