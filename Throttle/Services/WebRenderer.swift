import AppKit
import Foundation
@preconcurrency import WebKit

/// Sendable result of one render. Only value types cross the actor boundary back
/// to the bridge (Swift 6 strict concurrency).
struct WebRenderResult: Sendable {
    var ok: Bool
    var text: String = ""
    var title: String = ""
    var finalURL: String = ""
    var renderMs: Int = 0
    var truncated: Bool = false
    var waitReason: String = ""
    var error: String? = nil
}

/// The edge Claude Code's native WebFetch structurally lacks: WebFetch sees only
/// static server HTML, never the JavaScript-rendered DOM. `WebRenderer` drives a
/// real (offscreen) WKWebView so SPA / client-rendered pages produce their actual
/// visible text.
///
/// **Must run inside the menu-bar app** — WKWebView needs an `NSApplication`, the
/// main run loop, and a window that is on-screen (see the `makeHiddenHostWindow`
/// note cloned from `EmbeddedClaudeSession`: `orderOut(nil)` freezes rendering and
/// `evaluateJavaScript`/`callAsyncJavaScript` hang forever). The GUI-less
/// `--mcp-server` CLI can't host it, so the MCP tool is a thin loopback client to
/// this in-app renderer (see `WebRenderBridge` / `WebRenderClient`).
///
/// Privacy: an **ephemeral, non-persistent** data store — research browsing never
/// touches the persistent claude.ai cookie jar `EmbeddedClaudeSession` owns, so no
/// auth/credential bleed between the subscription path and the research path.
///
/// Memory discipline (16 GB Mac): one reused WKWebView, `about:blank` after every
/// render to free the page, and an idle teardown timer that drops the whole
/// view+window after a quiet period. Renders are serialized — one navigation at a
/// time — matching `EmbeddedClaudeSession`'s `inFlight` discipline.
@MainActor
final class WebRenderer: NSObject {
    static let shared = WebRenderer()

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var navContinuations: [CheckedContinuation<Void, Error>] = []
    private var navigating = false
    private var busy = false                     // one render at a time
    private var idleTeardown: Task<Void, Never>?

    private override init() { super.init() }

    // MARK: - Public

    /// Render `url` and return its readable text. Never throws — fail-open with
    /// `ok:false` + an `error` string so the bridge always has something to send.
    func render(url urlString: String,
                wait: String = "networkIdle",
                waitSelector: String? = nil,
                maxChars: Int = 12_000,
                timeoutMs: Int = 15_000) async -> WebRenderResult {
        // SSRF / scheme guard: http(s) only, and never internal hosts — the model
        // must not be steerable into rendering localhost admin panels or the LAN.
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !Self.isBlockedHost(host) else {
            return WebRenderResult(ok: false, error: "Refused: only public http(s) URLs are allowed (blocked scheme or private/loopback host).")
        }

        // Serialize: wait for any in-flight render to finish.
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        busy = true
        idleTeardown?.cancel()
        defer {
            busy = false
            scheduleIdleTeardown()
        }

        let started = Date()
        let cap = min(max(timeoutMs, 1_000), 30_000)   // hard ceiling 30s
        let view = ensureWebView()

        do {
            try await navigate(view, to: url, timeoutMs: cap)
        } catch {
            return WebRenderResult(ok: false, finalURL: view.url?.absoluteString ?? urlString,
                                   renderMs: Self.ms(since: started),
                                   error: "Navigation failed: \(error.localizedDescription)")
        }

        let waitReason = await awaitQuiescence(view, wait: wait, selector: waitSelector,
                                               deadline: started.addingTimeInterval(Double(cap) / 1000.0))

        var result = await extract(view, maxChars: maxChars)
        result.renderMs = Self.ms(since: started)
        result.waitReason = waitReason
        if result.finalURL.isEmpty { result.finalURL = view.url?.absoluteString ?? urlString }

        // Free the page's memory immediately; keep the (now-cheap) view warm.
        view.load(URLRequest(url: URL(string: "about:blank")!))
        return result
    }

    // MARK: - Quiescence

    /// Wait until the page is settled, capped at `deadline`. Layers: readyState
    /// complete, an innerText-length stability window (catches SPA hydration), and
    /// an optional `waitSelector`. Whichever settles first past a minimum, else the
    /// hard deadline. Never waits forever.
    private func awaitQuiescence(_ view: WKWebView, wait: String, selector: String?, deadline: Date) async -> String {
        let selCheck = selector.map { "!!document.querySelector(\(Self.jsString($0)))" } ?? "true"
        var lastLen = -1, stableTicks = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let probe = "return JSON.stringify({rs: document.readyState, len: (document.body ? document.body.innerText.length : 0), sel: \(selCheck)});"
            guard let json = try? await callAsync(view, probe),
                  let d = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let rs = obj["rs"] as? String ?? ""
            let len = (obj["len"] as? Int) ?? Int((obj["len"] as? Double) ?? 0)
            let sel = (obj["sel"] as? Bool) ?? false

            if selector != nil, sel { return "selector" }
            if wait == "load" { if rs == "complete" { return "load" } ; continue }
            // networkIdle heuristic: DOM text length stable across two samples.
            if rs == "complete" {
                if len == lastLen { stableTicks += 1 } else { stableTicks = 0 }
                lastLen = len
                if stableTicks >= 1 { return "networkIdle" }   // ~600ms stable
            }
        }
        return "timeout"
    }

    // MARK: - Extraction (readability-lite; no vendored JS dependency)

    private func extract(_ view: WKWebView, maxChars: Int) async -> WebRenderResult {
        // Strips chrome (nav/header/footer/aside/forms/scripts) from the LIVE DOM
        // — safe because we tear the page down right after — then takes the best
        // content container's rendered innerText (which requires layout, hence the
        // live node, not a detached clone).
        let js = """
        return (function(){
          try {
            var doc = document, title = doc.title || '';
            var junk = doc.querySelectorAll('script,style,noscript,svg,nav,header,footer,aside,form,button,iframe,[aria-hidden="true"],[role="navigation"],[role="banner"],[role="contentinfo"]');
            for (var i=0;i<junk.length;i++){ try{ junk[i].remove(); }catch(e){} }
            var cand = doc.querySelector('article') || doc.querySelector('main') || doc.querySelector('[role="main"]') || doc.body;
            var text = ((cand && (cand.innerText || cand.textContent)) || '').replace(/[\\t ]{2,}/g,' ').replace(/\\n{3,}/g,'\\n\\n').trim();
            return JSON.stringify({ title: title, text: text, url: location.href });
          } catch(e) { return JSON.stringify({ title: document.title || '', text: '', url: location.href, err: String(e) }); }
        })();
        """
        guard let json = try? await callAsync(view, js),
              let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return WebRenderResult(ok: false, finalURL: view.url?.absoluteString ?? "",
                                   error: "Extraction failed (page returned no parseable content).")
        }
        var text = obj["text"] as? String ?? ""
        let truncated = text.count > maxChars
        if truncated { text = String(text.prefix(maxChars)) }
        return WebRenderResult(ok: true, text: text,
                               title: obj["title"] as? String ?? "",
                               finalURL: obj["url"] as? String ?? "",
                               truncated: truncated)
    }

    // MARK: - Navigation (cloned from EmbeddedClaudeSession)

    private func navigate(_ view: WKWebView, to url: URL, timeoutMs: Int) async throws {
        while navigating { try? await Task.sleep(nanoseconds: 50_000_000) }
        navigating = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navContinuations.append(c)
            view.load(URLRequest(url: url))
        }
    }

    private func finishNavigation(error: Error?) {
        navigating = false
        let conts = navContinuations; navContinuations.removeAll()
        for c in conts { if let error { c.resume(throwing: error) } else { c.resume() } }
    }

    /// `callAsyncJavaScript` is the only WKWebView API that awaits a Promise on the
    /// WebKit side and hands Swift the resolved value; `evaluateJavaScript` returns
    /// the Promise object (WKErrorCode 5). Coerce to String inside the callback so
    /// only a Sendable value crosses the continuation.
    private func callAsync(_ view: WKWebView, _ body: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let s = value as? String { c.resume(returning: s) }
                    else if let n = value as? NSNumber { c.resume(returning: n.stringValue) }
                    else { c.resume(returning: "") }
                case .failure(let e): c.resume(throwing: e)
                }
            }
        }
    }

    // MARK: - WebView lifecycle

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // no cookie/auth carryover — privacy isolation
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        view.customUserAgent = EmbeddedClaudeSession.safariUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        let window = makeHiddenHostWindow()
        window.contentView = view
        self.hostWindow = window
        self.webView = view
        return view
    }

    /// See EmbeddedClaudeSession.makeHiddenHostWindow: WKWebView only renders when
    /// its window is ON screen. Keep it on-screen but invisible (off-canvas, alpha 0).
    private func makeHiddenHostWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1200, height: 900),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.alphaValue = 0
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.level = .floating
        w.orderBack(nil)
        return w
    }

    /// Drop the whole view + host window after a quiet period so a heavy WebKit
    /// content process isn't resident forever on a 16 GB Mac.
    private func scheduleIdleTeardown(after seconds: UInt64 = 90) {
        idleTeardown?.cancel()
        idleTeardown = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.busy else { return }
                self.webView?.navigationDelegate = nil
                self.webView = nil
                self.hostWindow?.contentView = nil
                self.hostWindow?.orderOut(nil)
                self.hostWindow = nil
            }
        }
    }

    // MARK: - Guards / helpers

    /// Block loopback, link-local, and RFC-1918 private ranges + `.local`, so the
    /// renderer can't be steered at the user's internal services. Best-effort host
    /// string check (public research targets are hostnames or public IPs).
    static func isBlockedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") { return true }
        if h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") { return true }
        if h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("169.254.") { return true }
        if h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let second = h.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? -1
            if (16...31).contains(second) { return true }
        }
        return false
    }

    private static func jsString(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8))?
            .dropFirst().dropLast().description ?? "\"\""
    }
    private static func ms(since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
}

// MARK: - Navigation + UI delegates

extension WebRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishNavigation(error: nil) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishNavigation(error: error) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishNavigation(error: error) }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.finishNavigation(error: EmbeddedSessionError.scriptError("WebKit content process died"))
        }
    }
}

/// Safety-critical: a hostile or ordinary page must never be able to deadlock the
/// shared renderer with a modal JS dialog. Auto-dismiss every panel type with a
/// safe default so `render()` always progresses.
extension WebRenderer: WKUIDelegate {
    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo) async { }
    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
    nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }
}
