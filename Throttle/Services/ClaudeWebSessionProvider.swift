import Foundation

/// Per-`send()` conversation cache. The Assistant tab generates a fresh
/// `ClaudeWebSessionScope.$sessionId` for every user-typed turn and clears
/// the entry when the recursion ends. Within that scope, every recursive
/// tool-result follow-up reuses the same claude.ai conversation UUID —
/// avoiding both (a) the cost of re-sending the 30-50 KB system prompt
/// every recursion, and (b) the soft rate-limit claude.ai applies when
/// you create N conversations in M seconds.
enum ClaudeWebSessionScope {
    @TaskLocal static var sessionId: UUID?
}

actor ClaudeWebSessionStore {
    static let shared = ClaudeWebSessionStore()
    private var convIds: [UUID: String] = [:]
    private var orgIds: [UUID: String] = [:]
    func conv(for id: UUID) -> String? { convIds[id] }
    func org(for id: UUID) -> String? { orgIds[id] }
    func set(conv: String, org: String, for id: UUID) {
        convIds[id] = conv
        orgIds[id] = org
    }
    func clear(_ id: UUID) {
        convIds.removeValue(forKey: id)
        orgIds.removeValue(forKey: id)
    }
}

/// AI provider that drives claude.ai's chat endpoint via Throttle's embedded,
/// user-authenticated session. No API key, no extra cost — every chat
/// counts against the user's existing Claude Pro/Max subscription, the
/// same way the embedded Exact Mode fallback reads usage.
///
/// Reverse-engineered protocol (claude.ai web app, April 2026):
///   1. GET  /api/organizations           → list of orgs, take first
///   2. POST /api/organizations/{org}/chat_conversations
///        body: {"uuid": <new uuid>, "name": "<title>"}
///        → creates a new conversation, returns its uuid
///   3. POST /api/organizations/{org}/chat_conversations/{conv}/completion
///        body: {"prompt": "<msg>", "attachments": [], "files": []}
///        → SSE stream of `data: {"type":"completion","completion":"…"}`
///          and `data: {"type":"content_block_delta",...}` events.
///
/// Risk: the endpoint shape may change without notice. Throttle already
/// accepts that risk for Exact Mode. If chat breaks, the provider
/// reports an `unavailable(reason:)` error and the user can switch to
/// Apple Intelligence or BYO API key.
struct ClaudeWebSessionProvider: AIProvider {
    let displayName = "Claude (your subscription)"
    let kind: AIProviderKind = .claudeWebSession

    var isAvailable: Bool {
        get async {
            await EmbeddedClaudeSession.shared.isSignedIn()
        }
    }

    /// Runs JavaScript only in Throttle's embedded session and returns a
    /// JSON-decodable payload. Safari automation is intentionally not a fallback.
    func runScript(_ script: String) async -> Result<Data, AIProviderError> {
        do {
            let str = try await EmbeddedClaudeSession.shared.runJS(script)
            guard let data = str.data(using: .utf8) else {
                return .failure(.decode("non-UTF8 from embedded session"))
            }
            return .success(data)
        } catch let err as EmbeddedSessionError {
            return .failure(.unavailable(reason: err.localizedDescription, recoverable: true))
        } catch {
            return .failure(.unavailable(reason: error.localizedDescription, recoverable: true))
        }
    }

    func streamChat(
        messages: [ChatMessage],
        context: ProjectChatContext
    ) async throws -> AsyncThrowingStream<String, Error> {
        // First turn (no cached convId) ships system prompt + full history
        // and creates a new conversation. Follow-up turns within the same
        // recursion ship ONLY the new user message and reuse the cached
        // convId — claude.ai retains the prior context server-side.
        let sessionId = ClaudeWebSessionScope.sessionId
        let cachedConv: String?
        let cachedOrg: String?
        if let id = sessionId {
            cachedConv = await ClaudeWebSessionStore.shared.conv(for: id)
            cachedOrg  = await ClaudeWebSessionStore.shared.org(for: id)
        } else {
            cachedConv = nil
            cachedOrg = nil
        }

        let promptPayload: String
        let reuse: (org: String, conv: String)?
        if let cachedConv, let cachedOrg {
            // Follow-up: send only the latest user message (typically a
            // tool_result block). Strip everything else.
            promptPayload = messages.last(where: { $0.role == .user })?.content ?? ""
            reuse = (cachedOrg, cachedConv)
        } else {
            // First turn: full payload.
            promptPayload = composePrompt(messages: messages, system: context.asSystemPrompt())
            reuse = nil
        }

        // Kickoff: sync-XHR org+conv setup, then fires off an async fetch
        // streaming the SSE response into `window.__throttle_buf`. Returns
        // immediately with `{_throttle_streaming: true, conv, org}` so we
        // can cache the conv ID before the model has finished generating.
        try Task.checkCancellation()
        let kickoff = await runScript(buildStreamingJS(prompt: promptPayload, reuse: reuse))

        switch kickoff {
        case .failure(let err):
            throw err
        case .success(let data):
            // Setup-phase errors come back as the same `_throttle_status`
            // envelope the legacy code returned — handle them before
            // entering the polling loop.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = obj["_throttle_status"] as? Int {
                let detail = (obj["_err"] as? String) ?? "HTTP \(status)"
                throw AIProviderError.unavailable(reason: detail, recoverable: true)
            }

            // Parse kickoff envelope: `{_throttle_streaming: true, conv, org}`
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let streaming = obj["_throttle_streaming"] as? Bool, streaming,
                  let conv = obj["conv"] as? String,
                  let org  = obj["org"]  as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                throw AIProviderError.decode("unexpected kickoff response: \(raw.prefix(200))")
            }

            // Cache conv/org early so a tool-recursion follow-up can reuse
            // it even if the streaming half fails midway.
            if let id = sessionId {
                await ClaudeWebSessionStore.shared.set(conv: conv, org: org, for: id)
            }

            // Streaming loop: poll the page's accumulator every 150 ms,
            // diff against last-emitted, yield each new chunk. Bail with
            // a recoverable error if the page reports `err`, or if we
            // never see any text and `done` flips before any deltas.
            let pollJS = buildPollJS()
            let logSnapshot = "session=\(sessionId?.uuidString.prefix(8) ?? "—") conv=\(conv.prefix(8))"
            return streamResponses(pollJS: pollJS, logSnapshot: logSnapshot)
        }
    }

    private func describe(_ err: SafariBridge.BridgeError) -> String {
        switch err {
        case .safariNotRunning:
            return String(localized: "Safari isn't running. Open Safari and sign in to claude.ai, then try again.")
        case .noClaudeTab:
            return String(localized: "No claude.ai tab open. Throttle tried to open one and failed.")
        case .automationDenied:
            return String(localized: "macOS denied automation. Open System Settings → Privacy & Security → Automation → Throttle → enable Safari, then try again.")
        case .notSignedIn:
            return String(localized: "You're signed out of claude.ai in Safari. Sign in and try again.")
        case .httpError(let code):
            return "claude.ai returned HTTP \(code)"
        case .invalidResponse:
            return String(localized: "Bad response from claude.ai.")
        case .appleScript(let s):
            return "AppleScript: \(s)"
        case .tabZombieRateLimited:
            return String(localized: "Safari discarded the claude.ai tab. Click the tab once to wake it, or paste a Claude API key in Settings to bypass the bridge entirely.")
        case .scriptError(let s):
            // Hard 429 from claude.ai. Format the resetsAt as a localized
            // relative date so the user knows when their budget comes back.
            if s.contains("rate_limit"),
               let resetsAt = Self.extractResetsAt(s),
               resetsAt > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(resetsAt))
                let fmt = RelativeDateTimeFormatter()
                fmt.unitsStyle = .full
                // Pin formatter locale to the bundle's resolved locale so
                // we don't get "Resets dans 3 heures" — system locale was
                // FR but the surrounding String(localized:) fell back to
                // English (no FR translation), producing a mix.
                fmt.locale = Self.uiLocale
                let when = fmt.localizedString(for: date, relativeTo: Date())
                let window: String
                if s.contains("five_hour") {
                    window = String(localized: "5-hour")
                } else if s.contains("seven_day") {
                    window = String(localized: "weekly")
                } else {
                    window = String(localized: "Pro/Max")
                }
                return String(localized: "Your Claude \(window) limit is exhausted. Resets \(when). Switch to Apple Intelligence or paste an API key in Settings to keep going.")
            }
            // status=200 + rawLen=0 = claude.ai aborted the stream before
            // writing any events. The JS probed /usage so we know which
            // window is actually constraining; pick the highest-util one.
            if s.contains("status=200"), s.contains("rawLen=0") {
                if let (windowKey, util, resets) = Self.worstWindow(in: s),
                   util >= 70 {
                    let windowLabel: String
                    switch windowKey {
                    case "five_hour":         windowLabel = String(localized: "5-hour")
                    case "seven_day":         windowLabel = String(localized: "weekly")
                    case "seven_day_sonnet":  windowLabel = String(localized: "weekly Sonnet")
                    case "seven_day_opus":    windowLabel = String(localized: "weekly Opus")
                    default:                  windowLabel = String(localized: "Pro/Max")
                    }
                    let when: String
                    if let resets, let date = Self.parseISO8601(resets) {
                        let fmt = RelativeDateTimeFormatter()
                        fmt.unitsStyle = .full
                        fmt.locale = Self.uiLocale
                        when = fmt.localizedString(for: date, relativeTo: Date())
                    } else {
                        when = String(localized: "soon")
                    }
                    return String(localized: "claude.ai dropped the response. Your \(windowLabel) limit is at \(util)% — the server is conserving capacity for short replies. Resets \(when). Switch to Apple Intelligence (free, on-device) or paste an API key in Settings to keep going now.")
                }
                // Probe failed or no window above threshold — fall back to
                // a generic "long answer near limit" hint.
                return String(localized: "claude.ai dropped the response — the predicted answer was long enough that the server declined to write it. Try a shorter follow-up, switch to Apple Intelligence, or paste a Claude API key in Settings.")
            }
            return "claude.ai: \(s)"
        }
    }

    /// Parse the `usage=[five_hour=12@... seven_day=85@... ...]` blob the
    /// JS bridge appends to the empty-stream diagnostic. Returns the window
    /// with the highest utilization (the one most likely to be the cause
    /// of the soft drop).
    private static func worstWindow(in s: String) -> (key: String, util: Int, resets: String?)? {
        guard let start = s.range(of: "usage=["),
              let end = s.range(of: "]", range: start.upperBound..<s.endIndex) else { return nil }
        let blob = s[start.upperBound..<end.lowerBound]
        var best: (String, Int, String?)?
        for token in blob.split(separator: " ") {
            // token like "seven_day=85@2026-05-05T14:00:01.174353+00:00"
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let valueAndResets = parts[1].split(separator: "@", maxSplits: 1)
            guard let util = Int(valueAndResets[0]) else { continue }
            let resets = valueAndResets.count > 1 ? String(valueAndResets[1]) : nil
            if best == nil || util > best!.1 {
                best = (key, util, resets)
            }
        }
        return best
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }

    /// Locale that matches the locale `String(localized:)` resolves to.
    /// `Bundle.main.preferredLocalizations` reflects the actual UI locale
    /// after intersection with the user's preferences. Without this,
    /// the date formatter follows system locale (FR) while the
    /// surrounding strings fall back to dev (EN) when a translation is
    /// missing — producing the "Resets dans 3 heures" mix from v2.6.1.
    private static var uiLocale: Locale {
        if let lang = Bundle.main.preferredLocalizations.first {
            return Locale(identifier: lang)
        }
        return Locale.current
    }

    /// Pull the `resetsAt=<epoch>` value out of the structured rate-limit
    /// diagnostic emitted by the JS bridge. Returns nil if the key is
    /// missing or unparseable.
    private static func extractResetsAt(_ s: String) -> Int? {
        guard let range = s.range(of: "resetsAt=") else { return nil }
        let tail = s[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }
}
