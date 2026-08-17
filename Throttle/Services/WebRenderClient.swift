import Foundation

/// CLI-side loopback client the `--mcp-server` process uses to reach the in-app
/// `WebRenderBridge` (127.0.0.1:4319). Plain Foundation + a semaphore so it can be
/// called from the synchronous JSON-RPC `handle` loop. On connection failure
/// (menu-bar app not running, or web bridge disabled) it returns an honest
/// "open Throttle" note rather than a stale or empty result (golden rule) — same
/// posture as the budget/cost tools when their snapshot is missing.
enum WebRenderClient {

    /// URLSession completion handlers are `@Sendable`. Keep the synchronous
    /// hand-off behind a lock instead of mutating a captured local variable.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Any]?

        func store(_ value: [String: Any]) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Returns the MCP `content`-ready text for a `web_render` call.
    static func render(url: String, wait: String?, waitSelector: String?, maxChars: Int?, timeoutMs: Int?, useCache: Bool? = nil, query: String? = nil) -> String {
        var req: [String: Any] = ["url": url]
        if let wait { req["wait"] = wait }
        if let waitSelector { req["waitSelector"] = waitSelector }
        if let maxChars { req["maxChars"] = maxChars }
        if let timeoutMs { req["timeoutMs"] = timeoutMs }
        if let useCache { req["useCache"] = useCache }
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { req["query"] = query }

        // Client timeout must outlast the render's hard 30 s ceiling.
        guard let resp = post(path: "/render", body: req, timeout: 35) else {
            return "Web renderer unavailable — open Throttle (the render engine runs inside the menu-bar app). Once it's running with Web research enabled, retry."
        }
        if let ok = resp["ok"] as? Bool, !ok {
            let err = resp["error"] as? String ?? "unknown error"
            return "web_render failed: \(err)"
        }
        let title = resp["title"] as? String ?? ""
        let finalURL = resp["finalURL"] as? String ?? url
        let ms = resp["renderMs"] as? Int ?? 0
        let reason = resp["waitReason"] as? String ?? ""
        let truncated = (resp["truncated"] as? Bool) ?? false
        let cacheHit = (resp["cacheHit"] as? Bool) ?? false
        let text = resp["text"] as? String ?? ""
        var head: String
        if cacheHit {
            let age = resp["cacheAgeSec"] as? Int ?? 0
            let ago = age < 60 ? "\(age)s" : "\(age / 60)m"
            head = "# \(title.isEmpty ? finalURL : title)\n\(finalURL)  ·  served from cache (rendered \(ago) ago, no re-render)"
        } else {
            head = "# \(title.isEmpty ? finalURL : title)\n\(finalURL)  ·  rendered in \(ms)ms (settle: \(reason))"
        }
        if truncated { head += "  ·  [focused packet; full original is rehydratable]" }
        var output = head + "\n\n" + (text.isEmpty ? "(no readable text extracted)" : text)
        if let links = resp["links"] as? [[String: String]], !links.isEmpty {
            let rows = links.prefix(12).map { link in
                let label = link["label"].flatMap { $0.isEmpty ? nil : $0 } ?? "Next page"
                return "- \(label): \(link["url"] ?? "")"
            }
            output += "\n\n## Safe relevant links for the next navigation\n" + rows.joined(separator: "\n")
        }
        return output
    }

    static func localSummary(throttleID: String, task: String, maxTokens: Int?) -> String {
        var body: [String: Any] = ["throttleID": throttleID, "task": task]
        if let maxTokens { body["maxTokens"] = maxTokens }
        guard let response = post(path: "/summarize", body: body, timeout: 90) else {
            return "Local summarizer unavailable — open Throttle and retry."
        }
        guard (response["ok"] as? Bool) == true else {
            return "Local summarizer failed: \(response["error"] as? String ?? "unknown error")"
        }
        let summary = response["summary"] as? String ?? ""
        return """
        # Local Qwen draft — verify against the original
        throttle_id: \(throttleID)
        This is probabilistic synthesis, not evidence. Use throttle_expand_pointer before relying on omitted details.

        \(summary)
        """
    }

    // MARK: - Loopback POST (sync)

    private static func post(path: String, body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:4319\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        r.timeoutInterval = timeout

        let sem = DispatchSemaphore(value: 0)
        let response = ResponseBox()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let task = URLSession(configuration: cfg).dataTask(with: r) { d, _, _ in
            defer { sem.signal() }
            guard let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            response.store(obj)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return response.load()
    }
}
