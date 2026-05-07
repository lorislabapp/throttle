import AppKit
import Foundation
@preconcurrency import WebKit
import OSLog

/// Throttle-owned claude.ai session backed by an embedded WKWebView.
///
/// Replaces the Safari Bridge for the "use my Claude Pro/Max subscription
/// without paying for an API key" path. The Safari Bridge required:
///   - macOS Automation permission for Throttle → Safari
///   - The user's main Safari to have a logged-in claude.ai tab open
///   - AppleScript-based sync XHR (with all its drawbacks)
/// All three are gone with this — Throttle now owns its own claude.ai
/// session, signed in once per Mac via a built-in WKWebView, persisted
/// across launches via a `WKWebsiteDataStore` keyed under
/// `~/Library/WebKit/com.lorislab.throttle/`. Cookies survive app
/// restarts, the user signs in only the first time.
///
/// The webview lives in a hidden, off-screen `NSWindow` so it can run JS
/// in the background without ever showing UI. When the user needs to
/// sign in or re-authenticate, a sheet temporarily reparents the view
/// into a visible window. After sign-in completes, the view goes back
/// to the hidden host.
///
/// Compared to Safari Bridge:
///   - No Safari dependency. Works regardless of the user's main browser.
///   - No Automation permission prompt.
///   - No "Open Safari and re-test" friction when the tab is closed/zombie.
///   - `evaluateJavaScript` is natively async — streaming uses
///     `WKScriptMessageHandler` for real-time deltas (cleaner than the
///     150 ms polling loop the Bridge needs).
///   - Auto-detection of the plan tier (`Pro` / `Max 5x` / `Max 20x`)
///     from `/api/organizations/{org}/usage` — no manual Settings step.
@MainActor
final class EmbeddedClaudeSession: NSObject {
    static let shared = EmbeddedClaudeSession()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "EmbeddedClaudeSession")

    /// The web view. Initialized lazily on first access so we don't pay
    /// the WebKit startup cost at app launch unless the user actually
    /// uses the subscription path.
    private var webView: WKWebView?

    /// Off-screen window that hosts the WKWebView during background
    /// operations (so the view has a window/parent and `evaluateJavaScript`
    /// runs reliably). Borderless, alpha 0, never visible. The same
    /// view is briefly reparented into the sign-in sheet when needed.
    private var hostWindow: NSWindow?

    /// Token-locked async work — only one navigation/evaluate at a time
    /// to avoid race conditions on `webView.evaluateJavaScript` and
    /// shared `__throttle_*` globals.
    private var inFlight: Task<Void, Never>?

    /// Last detected plan tier from the most recent successful
    /// `/usage` response. `nil` if we haven't fetched yet, or the
    /// response shape changed and the parser missed it.
    private(set) var detectedPlanID: String?

    /// Last detected plan label ("Pro" / "Max (5x)" / "Max (20x)")
    /// for UI display.
    private(set) var detectedPlanLabel: String?

    /// True when a navigation is in flight so callers can wait.
    private var navigationInProgress = false
    private var navigationContinuations: [CheckedContinuation<Void, Error>] = []

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Returns true iff the persisted cookie store has a valid claude.ai
    /// `sessionKey` (the auth cookie Anthropic sets on login). Cheap —
    /// no network round-trip, just reads the local cookie store.
    func isSignedIn() async -> Bool {
        let store = ensureWebView().configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.contains { c in
            c.name == "sessionKey" &&
            (c.domain.contains("claude.ai") || c.domain.contains(".anthropic.com"))
        }
    }

    /// Run an arbitrary JS expression in the webview's claude.ai context
    /// and return the result coerced to String. Equivalent to
    /// `SafariBridge.runClaudeAIScript` but without AppleScript.
    func runJS(_ js: String) async throws -> String {
        try await ensureLoaded()
        let webView = ensureWebView()
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let s = result as? String { return s }
            if let n = result as? NSNumber { return n.stringValue }
            if let dict = result as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: dict)
                return String(data: data, encoding: .utf8) ?? ""
            }
            if result == nil { return "" }
            return String(describing: result)
        } catch {
            logger.error("evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Fetch the same `/api/organizations/{org}/usage` endpoint the
    /// Safari Bridge fetches, but via the embedded session. Returns the
    /// raw JSON Data on success. Side-effect: parses + stores
    /// `detectedPlanID` / `detectedPlanLabel` for the calibration
    /// auto-tuner to consume.
    func fetchUsageJSON() async throws -> Data {
        let js = """
        (async function() {
            try {
                var orgsResp = await fetch('/api/organizations', {credentials: 'include', headers: {'Accept': 'application/json'}});
                if (orgsResp.status === 401) return JSON.stringify({_throttle_status: 401});
                if (!orgsResp.ok) return JSON.stringify({_throttle_status: orgsResp.status});
                var orgs = await orgsResp.json();
                if (!orgs || !orgs.length) return JSON.stringify({_throttle_status: 401});
                var orgId = orgs[0].uuid || orgs[0].id;
                if (!orgId) return JSON.stringify({_throttle_status: 500});
                var planTier = orgs[0].billable_usage_plan || orgs[0].usage_plan || (orgs[0].subscription && orgs[0].subscription.plan) || '';

                var usageResp = await fetch('/api/organizations/' + orgId + '/usage', {
                    credentials: 'include',
                    headers: {'Accept': 'application/json', 'anthropic-client-platform': 'web_claude_ai'}
                });
                if (usageResp.status === 401) return JSON.stringify({_throttle_status: 401});
                if (!usageResp.ok) return JSON.stringify({_throttle_status: usageResp.status});
                var usageJson = await usageResp.json();
                // Embed the plan tier into the response so Swift can
                // auto-calibrate without a second round-trip.
                usageJson._throttle_detected_plan = planTier;
                return JSON.stringify(usageJson);
            } catch (e) {
                return JSON.stringify({_throttle_status: -1, _err: String(e && e.message ? e.message : e)});
            }
        })()
        """

        // Block until any other navigation/evaluate finishes.
        let resultStr = try await runJS(js)
        guard let data = resultStr.data(using: .utf8) else {
            throw EmbeddedSessionError.decode("non-UTF8 response")
        }
        // Sentinel-error envelope.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = obj["_throttle_status"] as? Int {
            if status == 401 { throw EmbeddedSessionError.notSignedIn }
            if status > 0    { throw EmbeddedSessionError.httpError(status) }
            if let err = obj["_err"] as? String, !err.isEmpty {
                throw EmbeddedSessionError.scriptError(err)
            }
            throw EmbeddedSessionError.invalidResponse
        }

        // Auto-detect plan tier from the embedded `_throttle_detected_plan`
        // so the calibration UI never has to ask the user "what plan are
        // you on?". Mapping: claude.ai's plan IDs are stable; we match
        // them to Throttle's calibration tiers.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let planID = obj["_throttle_detected_plan"] as? String, !planID.isEmpty {
            self.detectedPlanID = planID
            self.detectedPlanLabel = Self.planLabel(for: planID)
            // Persist for the calibration UI / Stats advisor to consume.
            // The key matches what `StatsInline.currentPlanID` already
            // reads, so manual setting and auto-detect share storage.
            if let calibKey = Self.calibrationPlanKey(for: planID) {
                UserDefaults.standard.set(calibKey, forKey: "throttle.calibration.plan")
                logger.info("plan auto-detected: \(planID, privacy: .public) → calibration=\(calibKey, privacy: .public)")
            } else {
                logger.info("plan auto-detected: \(planID, privacy: .public) (no calibration mapping)")
            }
        }

        return data
    }

    /// Maps claude.ai's plan IDs to Throttle's calibration storage keys
    /// (`pro` / `max5x` / `max20x`). Other tiers (Team, Enterprise,
    /// Free) don't have calibration entries yet — return nil so we
    /// don't blow away a user's manual setting with a value the
    /// calibration engine can't handle.
    private static func calibrationPlanKey(for planID: String) -> String? {
        let lower = planID.lowercased()
        if lower.contains("max_20x") || lower.contains("max-20x") || lower.contains("max20x") { return "max20x" }
        if lower.contains("max_5x")  || lower.contains("max-5x")  || lower.contains("max5x")  { return "max5x" }
        if lower.contains("pro")     { return "pro" }
        return nil
    }

    // MARK: - Plan ID → label mapping

    /// Maps claude.ai's plan IDs (as returned in `/api/organizations`'s
    /// `billable_usage_plan` / `usage_plan` field) to user-facing labels.
    /// Unknown IDs fall through to a humanized version of the raw ID so
    /// new tiers don't break the UI.
    static func planLabel(for planID: String) -> String {
        let lower = planID.lowercased()
        if lower.contains("max_20x") || lower.contains("max-20x") || lower.contains("max20x") { return "Max (20x)" }
        if lower.contains("max_5x")  || lower.contains("max-5x")  || lower.contains("max5x")  { return "Max (5x)" }
        if lower.contains("pro")     { return "Pro" }
        if lower.contains("team")    { return "Team" }
        if lower.contains("enterprise") || lower.contains("ent") { return "Enterprise" }
        if lower.contains("free")    { return "Free" }
        return planID
    }

    // MARK: - WebView lifecycle

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Persistent data store keyed by a stable identifier. Cookies
        // survive app restarts; the user signs in only once per Mac.
        config.websiteDataStore = persistentDataStore()
        // Enable JS (it's the default, but be explicit — some macOS
        // releases ship with it gated behind preferences).
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        // Mimic Safari's User-Agent so claude.ai treats us identically
        // to a normal Safari tab (avoids cloudflare challenge variants
        // gated on UA).
        view.customUserAgent = Self.safariUserAgent
        view.navigationDelegate = self
        // Attach to a hidden window so the view is in a parent hierarchy
        // — `evaluateJavaScript` is unreliable on detached views.
        let window = makeHiddenHostWindow()
        window.contentView = view
        self.hostWindow = window
        self.webView = view
        return view
    }

    private func persistentDataStore() -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            // Stable UUID keyed to Throttle's bundle id so the store
            // survives across builds and Mac users (per-user via macOS).
            let id = UUID(uuidString: "5C2B2A35-8E3D-4F62-9D56-3A1A4F3F7C42")!
            return WKWebsiteDataStore(forIdentifier: id)
        } else {
            return .default()
        }
    }

    private func makeHiddenHostWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1024, height: 768),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.alphaValue = 0
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Order out — we never want this window in Mission Control or
        // the Dock's Window menu.
        w.orderOut(nil)
        return w
    }

    /// Mimic Safari 17 on macOS 14+ — claude.ai serves the same JS for
    /// this UA, no different cloudflare challenge path. Update if the
    /// site starts UA-sniffing for a newer Safari.
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Make sure the webview has navigated to claude.ai at least once
    /// in this app session. Without an initial navigation,
    /// `evaluateJavaScript` runs against `about:blank` and any
    /// `fetch('/api/...')` resolves against the wrong origin.
    private func ensureLoaded() async throws {
        let view = ensureWebView()
        if let url = view.url, url.host?.contains("claude.ai") == true {
            return
        }
        try await navigate(to: URL(string: "https://claude.ai/")!)
    }

    /// Navigate the webview to `url` and wait for the navigation to
    /// finish. Bridges `WKNavigationDelegate` callbacks to async/await.
    fileprivate func navigate(to url: URL) async throws {
        let view = ensureWebView()
        await waitForCurrentNavigation()
        navigationInProgress = true
        return try await withCheckedThrowingContinuation { continuation in
            navigationContinuations.append(continuation)
            view.load(URLRequest(url: url))
        }
    }

    fileprivate func notifyNavigationFinished(error: Error?) {
        navigationInProgress = false
        let conts = navigationContinuations
        navigationContinuations.removeAll()
        for c in conts {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    private func waitForCurrentNavigation() async {
        while navigationInProgress {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Sign-in window

    /// Reparent the webview into a visible window, navigate to
    /// claude.ai/login, and return when the session cookie appears or
    /// the window is closed. The same WKWebView instance is reused so
    /// any state the user accumulates during sign-in (cookies, local
    /// storage) sticks.
    func presentSignIn() async -> Bool {
        let view = ensureWebView()
        // Snapshot the host window — we'll restore the view there after
        // sign-in regardless of outcome.
        let originalHost = self.hostWindow

        let signInWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        signInWindow.title = String(localized: "Sign in to claude.ai")
        signInWindow.center()
        signInWindow.contentView = view
        // Make sure we navigate the view to the login page when the
        // window opens so the user sees the sign-in form, not whatever
        // the background view was showing.
        view.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        signInWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Poll the cookie store every 500 ms; close the sheet when the
        // sessionKey appears (= sign-in success) or the window closes.
        let success: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            // Closed-window observer
            let closeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: signInWindow,
                queue: .main
            ) { _ in
                if !resumed {
                    resumed = true
                    continuation.resume(returning: false)
                }
            }
            // Cookie watcher
            let pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let signed = await self.isSignedIn()
                    if signed {
                        if !resumed {
                            resumed = true
                            continuation.resume(returning: true)
                            signInWindow.close()
                        }
                        return
                    }
                }
            }
            // Cleanup
            Task { @MainActor in
                while !resumed { try? await Task.sleep(nanoseconds: 200_000_000) }
                pollTask.cancel()
                NotificationCenter.default.removeObserver(closeToken)
            }
        }

        // Restore the view to the hidden host so background API calls
        // keep working.
        if let originalHost {
            originalHost.contentView = view
            originalHost.orderOut(nil)
        }
        return success
    }
}

// MARK: - WKNavigationDelegate

extension EmbeddedClaudeSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.notifyNavigationFinished(error: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.notifyNavigationFinished(error: error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.notifyNavigationFinished(error: error) }
    }
}

// MARK: - Errors

enum EmbeddedSessionError: Error, LocalizedError {
    case notSignedIn
    case httpError(Int)
    case invalidResponse
    case scriptError(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:        return String(localized: "Not signed in to claude.ai. Open Throttle's sign-in window.")
        case .httpError(let c):   return "claude.ai HTTP \(c)"
        case .invalidResponse:    return String(localized: "claude.ai returned an unexpected response.")
        case .scriptError(let s): return "claude.ai script error: \(s)"
        case .decode(let what):   return "Decoding failed: \(what)"
        }
    }
}
