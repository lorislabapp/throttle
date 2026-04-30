import AppKit
import Foundation
import OSLog

/// Drives the user's running Safari via AppleScript to fetch claude.ai's
/// `/api/organizations/{org}/usage` endpoint. Safari already has the user's
/// sessionKey + cf_clearance + login state — we ride on that and never
/// touch cookies ourselves.
///
/// The Safari `do JavaScript` AppleScript command runs JS in a tab's
/// context with `credentials: 'include'`, so cookies travel with the
/// request automatically.
///
/// Permission model:
///   - macOS prompts for Automation permission ("Throttle wants to control
///     Safari") on the first run.
///   - User can revoke any time in System Settings → Privacy & Security →
///     Automation. We surface a clear error when permission is denied.
///
/// Failure modes:
///   - Safari not running                → `.safariNotRunning`
///   - No claude.ai tab open + opening fails → `.noClaudeTab`
///   - Automation permission denied      → `.automationDenied`
///   - User signed out of claude.ai      → `.notSignedIn` (XHR returns 401)
///   - claude.ai network/server error    → `.httpError(code)`
@MainActor
enum SafariBridge {
    private static let logger = Logger(subsystem: "com.lorislab.throttle", category: "SafariBridge")

    enum BridgeError: Error, Sendable, Equatable {
        case safariNotRunning
        case noClaudeTab
        case automationDenied
        case notSignedIn
        case httpError(Int)
        case invalidResponse
        case appleScript(String)
        /// JS threw or surfaced a diagnostic via `_throttle_status: <negative>`
        /// + `_err: "..."`. Used by ClaudeWebSession to bubble the raw
        /// claude.ai response shape back to the user when our SSE parser
        /// finds nothing usable.
        case scriptError(String)
    }

    /// Open https://claude.ai/settings/usage in the user's default Safari
    /// (creates a new window if none open). Used by the "Sign in" button.
    static func openClaudeUsagePage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True iff Safari.app is currently running.
    static var isSafariRunning: Bool {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Safari"
        ).first != nil
    }

    /// Run an arbitrary block of JavaScript in the user's Safari claude.ai
    /// tab and return its `return` value as raw bytes. The JS runs with the
    /// user's logged-in cookies (`credentials: 'include'` is implicit), so
    /// any claude.ai API endpoint is callable. Used by ClaudeWebSession
    /// AI provider to POST chat completions through the user's plan.
    ///
    /// The JS MUST use synchronous XHR — AppleScript's `do JavaScript`
    /// cannot await Promises (it would serialize as `[object Promise]`).
    /// For SSE responses, read `responseText` after the request completes.
    static func runClaudeAIScript(_ js: String) async -> Result<Data, BridgeError> {
        guard isSafariRunning else { return .failure(.safariNotRunning) }
        let jsAsAppleScriptLiteral = appleScriptStringLiteral(js)
        // The probe script verifies the tab's *document* (not just the URL
        // bar) is on claude.ai before running the real JS. Safari can leave
        // a tab in a zombie state where the URL bar reads "claude.ai" but
        // `document.location.href` is still `about:blank`. In that state any
        // relative XHR resolves against about:blank and throws "SyntaxError:
        // The string did not match the expected pattern." If we detect it
        // we force a navigation and wait for `document.readyState === complete`
        // before continuing — otherwise the JS runs against a dead document.
        let script = """
        tell application "Safari"
            set targetTab to missing value
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "claude.ai" then
                            set targetTab to t
                            exit repeat
                        end if
                    end repeat
                    if targetTab is not missing value then exit repeat
                end repeat
            end try
            if targetTab is missing value then
                try
                    tell window 1 to set targetTab to make new tab with properties {URL:"https://claude.ai/settings/usage"}
                    delay 2
                on error
                    return "__THROTTLE_NO_TAB__"
                end try
            end if
            -- Probe document state. If the tab is zombie (about:blank), force
            -- a real navigation and wait up to 6s for the load to complete.
            try
                set probeJS to "(function(){ try { return document.location.href + '|' + document.readyState; } catch(e) { return 'about:blank|complete'; } })()"
                set probeResult to do JavaScript probeJS in targetTab
                if (probeResult as string) does not contain "claude.ai" then
                    set URL of targetTab to "https://claude.ai/settings/usage"
                    set tries to 0
                    repeat
                        delay 0.5
                        try
                            set probeResult to do JavaScript probeJS in targetTab
                            if (probeResult as string) contains "claude.ai" and (probeResult as string) contains "complete" then
                                exit repeat
                            end if
                        end try
                        set tries to tries + 1
                        if tries > 12 then exit repeat
                    end repeat
                end if
            end try
            try
                set jsResult to do JavaScript \(jsAsAppleScriptLiteral) in targetTab
                return jsResult as string
            on error errMsg number errNum
                return "__THROTTLE_AS_ERR__:" & errNum & ":" & errMsg
            end try
        end tell
        """
        return await Task.detached { () -> Result<Data, BridgeError> in
            let result = runAppleScript(source: script)
            return handleAppleScriptResult(result)
        }.value
    }

    /// Fetch the usage JSON via Safari. Returns the raw JSON Data on success.
    static func fetchUsageJSON() async -> Result<Data, BridgeError> {
        guard isSafariRunning else { return .failure(.safariNotRunning) }

        // The JS uses synchronous XHR (yes, deprecated, yes, fine here) so
        // the AppleScript `do JavaScript` returns the response body as a
        // string instead of a Promise representation. Async/await would
        // serialize as "[object Promise]" — useless to us.
        //
        // We chain two requests:
        //   1. /api/organizations  → first org's UUID
        //   2. /api/organizations/{uuid}/usage  → the usage payload
        //
        // We return a sentinel JSON object {"_throttle_status": <int>, ...}
        // so we can route 401/403 to the right Swift error.
        let js = """
        (function() {
            try {
                var orgsX = new XMLHttpRequest();
                orgsX.open('GET', '/api/organizations', false);
                orgsX.setRequestHeader('Accept', 'application/json');
                orgsX.send();
                if (orgsX.status === 401) return JSON.stringify({_throttle_status: 401});
                if (orgsX.status >= 400) return JSON.stringify({_throttle_status: orgsX.status});
                var orgs = JSON.parse(orgsX.responseText);
                if (!orgs || !orgs.length) return JSON.stringify({_throttle_status: 401});
                var orgId = orgs[0].uuid || orgs[0].id;
                if (!orgId) return JSON.stringify({_throttle_status: 500});

                var usageX = new XMLHttpRequest();
                usageX.open('GET', '/api/organizations/' + orgId + '/usage', false);
                usageX.setRequestHeader('Accept', 'application/json');
                usageX.setRequestHeader('anthropic-client-platform', 'web_claude_ai');
                usageX.send();
                if (usageX.status === 401) return JSON.stringify({_throttle_status: 401});
                if (usageX.status >= 400) return JSON.stringify({_throttle_status: usageX.status});
                return usageX.responseText;
            } catch (e) {
                return JSON.stringify({_throttle_status: -1, _err: String(e)});
            }
        })()
        """

        // Wrap the JS in a heredoc so single quotes inside don't break the
        // AppleScript literal. AppleScript multi-line strings are tricky;
        // we use chained `&` concatenation for safety.
        let jsAsAppleScriptLiteral = appleScriptStringLiteral(js)

        let script = """
        tell application "Safari"
            set targetTab to missing value
            try
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "claude.ai" then
                            set targetTab to t
                            exit repeat
                        end if
                    end repeat
                    if targetTab is not missing value then exit repeat
                end repeat
            end try
            if targetTab is missing value then
                try
                    tell window 1 to set targetTab to make new tab with properties {URL:"https://claude.ai/settings/usage"}
                    delay 2
                on error
                    return "__THROTTLE_NO_TAB__"
                end try
            end if
            -- Probe document state. The tab can read "claude.ai" in the URL
            -- bar while `document.location.href` is still about:blank, in which
            -- case any relative XHR throws "SyntaxError: The string did not
            -- match the expected pattern." Force-navigate and wait for load.
            try
                set probeJS to "(function(){ try { return document.location.href + '|' + document.readyState; } catch(e) { return 'about:blank|complete'; } })()"
                set probeResult to do JavaScript probeJS in targetTab
                if (probeResult as string) does not contain "claude.ai" then
                    set URL of targetTab to "https://claude.ai/settings/usage"
                    set tries to 0
                    repeat
                        delay 0.5
                        try
                            set probeResult to do JavaScript probeJS in targetTab
                            if (probeResult as string) contains "claude.ai" and (probeResult as string) contains "complete" then
                                exit repeat
                            end if
                        end try
                        set tries to tries + 1
                        if tries > 12 then exit repeat
                    end repeat
                end if
            end try
            try
                set jsResult to do JavaScript \(jsAsAppleScriptLiteral) in targetTab
                return jsResult as string
            on error errMsg number errNum
                return "__THROTTLE_AS_ERR__:" & errNum & ":" & errMsg
            end try
        end tell
        """

        return await Task.detached { () -> Result<Data, BridgeError> in
            let result = runAppleScript(source: script)
            return handleAppleScriptResult(result)
        }.value
    }

    private nonisolated static func handleAppleScriptResult(_ result: AppleScriptResult) -> Result<Data, BridgeError> {
        switch result {
        case .failure(let err):
            // -1743 = not authorized to send Apple events to Safari (user denied
            // Automation permission). -1719 ≈ similar invalid event tier.
            if err.contains("-1743") || err.lowercased().contains("not authorized") {
                return .failure(.automationDenied)
            }
            if err.contains("-600") {
                return .failure(.safariNotRunning)
            }
            return .failure(.appleScript(err))
        case .success(let str):
            if str == "__THROTTLE_NO_TAB__" { return .failure(.noClaudeTab) }
            if str.hasPrefix("__THROTTLE_AS_ERR__:") {
                if str.contains("-1743") { return .failure(.automationDenied) }
                return .failure(.appleScript(str))
            }
            guard let data = str.data(using: .utf8) else {
                return .failure(.invalidResponse)
            }
            // Detect our sentinel error wrapper.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = obj["_throttle_status"] as? Int {
                if status == 401 { return .failure(.notSignedIn) }
                if status > 0    {
                    if let err = obj["_err"] as? String, !err.isEmpty {
                        return .failure(.scriptError("HTTP \(status): \(err)"))
                    }
                    return .failure(.httpError(status))
                }
                if let err = obj["_err"] as? String, !err.isEmpty {
                    return .failure(.scriptError(err))
                }
                return .failure(.invalidResponse)
            }
            return .success(data)
        }
    }

    // MARK: - AppleScript helpers

    private enum AppleScriptResult {
        case success(String)
        case failure(String)
    }

    private nonisolated static func runAppleScript(source: String) -> AppleScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure("Failed to parse AppleScript")
        }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
            let num = (error[NSAppleScript.errorNumber] as? Int).map { "\($0)" } ?? ""
            return .failure("\(num): \(msg)")
        }
        return .success(descriptor.stringValue ?? "")
    }

    /// Wrap a Swift string in AppleScript-safe `&`-concatenated chunks.
    /// AppleScript single-quote handling differs from Swift, so we split
    /// on every double-quote and rebuild as `"...part1..." & "\\"" & "...part2..."`.
    private static func appleScriptStringLiteral(_ s: String) -> String {
        // AppleScript string literals: enclose in `"`, escape `"` as `\"`,
        // escape `\` as `\\`. Also, multi-line literals work in modern
        // AppleScript so we just need to escape backslashes and quotes.
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
