import Foundation

/// CLI-side loopback client the `--mcp-server` process uses to reach the in-app
/// `WebRenderBridge` (127.0.0.1:4319). Plain Foundation + a semaphore so it can be
/// called from the synchronous JSON-RPC `handle` loop. On connection failure
/// (menu-bar app not running, or web bridge disabled) it returns an honest
/// "open Throttle" note rather than a stale or empty result (golden rule) — same
/// posture as the budget/cost tools when their snapshot is missing.
enum WebRenderClient {

    /// Returns the MCP `content`-ready text for a `web_render` call.
    static func render(url: String, wait: String?, waitSelector: String?, maxChars: Int?, timeoutMs: Int?, useCache: Bool? = nil) -> String {
        var req: [String: Any] = ["url": url]
        if let wait { req["wait"] = wait }
        if let waitSelector { req["waitSelector"] = waitSelector }
        if let maxChars { req["maxChars"] = maxChars }
        if let timeoutMs { req["timeoutMs"] = timeoutMs }
        if let useCache { req["useCache"] = useCache }

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
        if truncated { head += "  ·  [truncated]" }
        return head + "\n\n" + (text.isEmpty ? "(no readable text extracted)" : text)
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
        var out: [String: Any]?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let task = URLSession(configuration: cfg).dataTask(with: r) { d, _, _ in
            defer { sem.signal() }
            guard let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            out = obj
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return out
    }
}
