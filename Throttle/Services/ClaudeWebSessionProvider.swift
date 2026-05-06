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

/// AI provider that drives claude.ai's chat endpoint via the user's
/// logged-in Safari session. No API key, no extra cost — every chat
/// counts against the user's existing Claude Pro/Max subscription, the
/// same way Throttle's Exact Mode reads `/api/organizations/{org}/usage`
/// through Safari's cookies.
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
            // We can't verify the full chat path without making a real
            // request — the cheap proxy is "is the usage endpoint
            // reachable through Safari?". Same prerequisites apply.
            await MainActor.run { SafariBridge.isSafariRunning }
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
        let kickoff = await SafariBridge.runClaudeAIScript(buildStreamingJS(prompt: promptPayload, reuse: reuse))

        switch kickoff {
        case .failure(let err):
            throw AIProviderError.unavailable(reason: describe(err), recoverable: true)
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
            return AsyncThrowingStream { continuation in
                Task {
                    var emittedLength = 0
                    var pollsBeforeAnyText = 0
                    // Recursive tool-result turns can take 30–50 s before
                    // first token (claude.ai server-side digests the
                    // tool_results, runs prompt-cache checks, then plans).
                    // 60 s of total silence is a fairer "the stream really
                    // dropped" signal — anything sooner caused false
                    // positives where the model was just thinking hard.
                    let maxPollsBeforeAnyText = 400  // 60 s of nothing → bail
                    var totalPolls = 0
                    let maxTotalPolls = 1200          // 3 min absolute cap
                    while !Task.isCancelled {
                        totalPolls += 1
                        if totalPolls > maxTotalPolls {
                            continuation.finish(throwing: AIProviderError.unavailable(
                                reason: "claude.ai stream still running after 3 min — giving up.", recoverable: true))
                            return
                        }
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        let pollResult = await SafariBridge.runClaudeAIScript(pollJS)
                        switch pollResult {
                        case .failure(let bridgeErr):
                            continuation.finish(throwing: AIProviderError.unavailable(
                                reason: self.describe(bridgeErr), recoverable: true))
                            return
                        case .success(let pollData):
                            guard let pobj = try? JSONSerialization.jsonObject(with: pollData) as? [String: Any] else {
                                continue
                            }
                            if let errMsg = pobj["err"] as? String, !errMsg.isEmpty {
                                continuation.finish(throwing: AIProviderError.unavailable(
                                    reason: "claude.ai stream error (\(logSnapshot)): \(errMsg)", recoverable: true))
                                return
                            }
                            let buf = (pobj["buf"] as? String) ?? ""
                            if buf.count > emittedLength {
                                let delta = String(buf.dropFirst(emittedLength))
                                emittedLength = buf.count
                                continuation.yield(delta)
                            } else if buf.isEmpty {
                                pollsBeforeAnyText += 1
                                if pollsBeforeAnyText >= maxPollsBeforeAnyText {
                                    continuation.finish(throwing: AIProviderError.unavailable(
                                        reason: String(localized: "claude.ai dropped the response — you're likely near your 5-hour Pro/Max limit. Wait until the next reset or switch to Apple Intelligence / a Claude API key in Settings."),
                                        recoverable: true))
                                    return
                                }
                            }
                            if let isDone = pobj["done"] as? Bool, isDone {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Prompt + JS

    private func composePrompt(messages: [ChatMessage], system: String) -> String {
        // claude.ai's `prompt` field doesn't accept a separate system
        // role — we prepend the system context as a "Context:" block
        // followed by the chat history.
        var lines: [String] = []
        lines.append("Context:")
        lines.append(system)
        lines.append("")
        for msg in messages where msg.role != .system {
            switch msg.role {
            case .user:      lines.append("User: \(msg.content)")
            case .assistant: lines.append("Assistant: \(msg.content)")
            case .system:    continue
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Returns a tiny JS that reads the page's streaming accumulator.
    /// Polled by `streamChat` every 150 ms while a turn is in flight.
    /// The 4 keys (`buf`, `done`, `err`, `conv`/`org` are unused here —
    /// they're set by the kickoff JS) come back as a JSON object.
    private func buildPollJS() -> String {
        return """
        JSON.stringify({
            buf: window.__throttle_buf || '',
            done: window.__throttle_done === true,
            err: window.__throttle_err || ''
        })
        """
    }

    /// Streaming kickoff. Synchronously runs org-lookup + conv-creation
    /// (those are cheap and we want the IDs back to Swift right away so
    /// a tool-recursion follow-up can re-enter with `reuse=`), then
    /// fires off an async `fetch()` for the SSE completion endpoint
    /// whose ReadableStream reader appends each text delta into
    /// `window.__throttle_buf`. Returns synchronously with
    /// `{_throttle_streaming: true, conv, org}` once the async pump is
    /// running. Swift then polls `__throttle_buf` via `buildPollJS()`
    /// and yields deltas as they arrive.
    ///
    /// Streaming changes the UX from "wait 8 s, see whole answer" to
    /// "first token in ~600 ms, watch it write". The protocol shape is
    /// unchanged from the legacy `buildJS()` flow — same endpoints,
    /// same SSE event shapes, same field-name fallback (`completion`,
    /// `delta.text`, `delta.content`, `message.content`, `text`).
    private func buildStreamingJS(prompt: String, reuse: (org: String, conv: String)?) -> String {
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let reuseOrgJS  = reuse.map { "\"\($0.org)\"" }  ?? "null"
        let reuseConvJS = reuse.map { "\"\($0.conv)\"" } ?? "null"
        return """
        (function() {
            try {
                // Reset accumulator state for this turn. Earlier turns'
                // values must be wiped or the poll loop emits stale text
                // as the new turn's first delta.
                window.__throttle_buf  = '';
                window.__throttle_done = false;
                window.__throttle_err  = '';

                var reuseOrg  = \(reuseOrgJS);
                var reuseConv = \(reuseConvJS);
                var orgId  = reuseOrg;
                var convId = reuseConv;

                if (!orgId || !convId) {
                    var orgsX = new XMLHttpRequest();
                    orgsX.open('GET', '/api/organizations', false);
                    orgsX.setRequestHeader('Accept', 'application/json');
                    orgsX.send();
                    if (orgsX.status >= 400) return JSON.stringify({_throttle_status: orgsX.status});
                    var orgs = JSON.parse(orgsX.responseText);
                    if (!orgs || !orgs.length) return JSON.stringify({_throttle_status: 401});
                    orgId = orgs[0].uuid || orgs[0].id;

                    function uuid4() {
                        return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, function(c) {
                            return (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16);
                        });
                    }
                    convId = uuid4();
                    var createX = new XMLHttpRequest();
                    createX.open('POST', '/api/organizations/' + orgId + '/chat_conversations', false);
                    createX.setRequestHeader('Content-Type', 'application/json');
                    createX.setRequestHeader('Accept', 'application/json');
                    createX.setRequestHeader('anthropic-client-platform', 'web_claude_ai');
                    createX.send(JSON.stringify({uuid: convId, name: 'Throttle assistant'}));
                    if (createX.status >= 400) return JSON.stringify({_throttle_status: createX.status, _err: 'create:' + createX.responseText.substring(0,200)});
                }

                // Async streaming pump. Started before this function
                // returns; runs concurrently while Swift polls the
                // window globals via `buildPollJS()`.
                (async function() {
                    try {
                        var compResp = await fetch('/api/organizations/' + orgId + '/chat_conversations/' + convId + '/completion', {
                            method: 'POST',
                            credentials: 'include',
                            headers: {
                                'Content-Type': 'application/json',
                                'Accept': 'text/event-stream',
                                'anthropic-client-platform': 'web_claude_ai'
                            },
                            body: JSON.stringify({
                                prompt: "\(escapedPrompt)",
                                attachments: [],
                                files: [],
                                timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
                            })
                        });
                        if (compResp.status === 429) {
                            var rep = '', resetsAt = 0;
                            try {
                                var bodyText = await compResp.text();
                                var bodyJson = JSON.parse(bodyText);
                                var em = bodyJson && bodyJson.error && bodyJson.error.message;
                                if (em && typeof em === 'object') {
                                    rep = em.representativeClaim || '';
                                    resetsAt = em.resetsAt || 0;
                                }
                            } catch(e) {}
                            window.__throttle_err = 'rate_limit window=' + rep + ' resetsAt=' + resetsAt;
                            window.__throttle_done = true;
                            return;
                        }
                        if (!compResp.ok) {
                            var bt = '';
                            try { bt = (await compResp.text()).substring(0,200); } catch(e) {}
                            window.__throttle_err = 'complete:' + compResp.status + ' ' + bt;
                            window.__throttle_done = true;
                            return;
                        }

                        var reader = compResp.body.getReader();
                        var decoder = new TextDecoder();
                        var pending = '';
                        while (true) {
                            var step = await reader.read();
                            if (step.done) break;
                            pending += decoder.decode(step.value, {stream: true});
                            // Process all complete lines we have so far.
                            var nl;
                            while ((nl = pending.indexOf('\\n')) !== -1) {
                                var line = pending.substring(0, nl);
                                pending = pending.substring(nl + 1);
                                if (!line || line.indexOf('data:') !== 0) continue;
                                var payload = line.substring(5).trim();
                                if (!payload || payload === '[DONE]') continue;
                                try {
                                    var ev = JSON.parse(payload);
                                    if (typeof ev.completion === 'string') window.__throttle_buf += ev.completion;
                                    if (ev.delta && typeof ev.delta.text === 'string') window.__throttle_buf += ev.delta.text;
                                    if (ev.delta && typeof ev.delta.content === 'string') window.__throttle_buf += ev.delta.content;
                                    if (ev.message && typeof ev.message.content === 'string') window.__throttle_buf += ev.message.content;
                                    if (typeof ev.text === 'string') window.__throttle_buf += ev.text;
                                } catch (e) { /* malformed line, ignore */ }
                            }
                        }
                        window.__throttle_done = true;
                    } catch (e) {
                        window.__throttle_err = String((e && e.message) ? e.message : e);
                        window.__throttle_done = true;
                    }
                })();

                // Synchronous return — hand conv/org back to Swift so it
                // can cache before the stream finishes (a follow-up turn
                // arrives with the conv pre-warmed).
                return JSON.stringify({
                    _throttle_streaming: true,
                    conv: convId,
                    org: orgId
                });
            } catch (e) {
                return JSON.stringify({_throttle_status: -1, _err: String(e)});
            }
        })()
        """
    }

    private func buildJS(prompt: String, reuse: (org: String, conv: String)?) -> String {
        // Embed the prompt as a JS string. Escape backslashes, quotes,
        // and newlines so the AppleScript-wrapped JS literal stays well-
        // formed regardless of the user's input.
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let reuseOrgJS  = reuse.map { "\"\($0.org)\"" }  ?? "null"
        let reuseConvJS = reuse.map { "\"\($0.conv)\"" } ?? "null"
        return """
        (function() {
            try {
                var reuseOrg  = \(reuseOrgJS);
                var reuseConv = \(reuseConvJS);
                var orgId = reuseOrg;
                var convId = reuseConv;

                if (!orgId || !convId) {
                    // Step 1: get org id.
                    var orgsX = new XMLHttpRequest();
                    orgsX.open('GET', '/api/organizations', false);
                    orgsX.setRequestHeader('Accept', 'application/json');
                    orgsX.send();
                    if (orgsX.status >= 400) return JSON.stringify({_throttle_status: orgsX.status});
                    var orgs = JSON.parse(orgsX.responseText);
                    if (!orgs || !orgs.length) return JSON.stringify({_throttle_status: 401});
                    orgId = orgs[0].uuid || orgs[0].id;

                    // Step 2: create a conversation.
                    function uuid4() {
                        return ([1e7]+-1e3+-4e3+-8e3+-1e11).replace(/[018]/g, function(c) {
                            return (c ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> c / 4).toString(16);
                        });
                    }
                    convId = uuid4();
                    var createX = new XMLHttpRequest();
                    createX.open('POST', '/api/organizations/' + orgId + '/chat_conversations', false);
                    createX.setRequestHeader('Content-Type', 'application/json');
                    createX.setRequestHeader('Accept', 'application/json');
                    createX.setRequestHeader('anthropic-client-platform', 'web_claude_ai');
                    createX.send(JSON.stringify({uuid: convId, name: 'Throttle assistant'}));
                    if (createX.status >= 400) return JSON.stringify({_throttle_status: createX.status, _err: 'create:' + createX.responseText.substring(0,200)});
                }

                // Step 3: send completion request — sync XHR collects the
                // full SSE text. We then walk the events in JS.
                var compX = new XMLHttpRequest();
                compX.open('POST', '/api/organizations/' + orgId + '/chat_conversations/' + convId + '/completion', false);
                compX.setRequestHeader('Content-Type', 'application/json');
                compX.setRequestHeader('Accept', 'text/event-stream');
                compX.setRequestHeader('anthropic-client-platform', 'web_claude_ai');
                var promptStr = "\(escapedPrompt)";
                var compBody = JSON.stringify({
                    prompt: promptStr,
                    attachments: [],
                    files: [],
                    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
                });
                compX.send(compBody);
                if (compX.status === 429) {
                    // Hard rate-limit. Parse the structured body for resetsAt
                    // + which window (five_hour / seven_day) so Swift can
                    // surface a human-readable "Resets in 47 min" message.
                    var rep = '', resetsAt = 0;
                    try {
                        var body = JSON.parse(compX.responseText);
                        var em = body && body.error && body.error.message;
                        if (em && typeof em === 'object') {
                            rep = em.representativeClaim || '';
                            resetsAt = em.resetsAt || 0;
                        }
                    } catch(e) {}
                    return JSON.stringify({_throttle_status: 429, _err: 'rate_limit window=' + rep + ' resetsAt=' + resetsAt});
                }
                if (compX.status >= 400) return JSON.stringify({_throttle_status: compX.status, _err: 'complete:' + compX.responseText.substring(0,200)});

                // Concatenate every text delta from the SSE stream.
                var raw = compX.responseText;
                var lines = raw.split('\\n');
                var out = '';
                var dataLines = 0;
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i];
                    if (!line || line.indexOf('data:') !== 0) continue;
                    dataLines++;
                    var payload = line.substring(5).trim();
                    if (!payload || payload === '[DONE]') continue;
                    try {
                        var ev = JSON.parse(payload);
                        // Try every plausible field name across versions.
                        if (typeof ev.completion === 'string') out += ev.completion;
                        if (ev.delta && typeof ev.delta.text === 'string') out += ev.delta.text;
                        if (ev.delta && typeof ev.delta.content === 'string') out += ev.delta.content;
                        if (ev.message && typeof ev.message.content === 'string') out += ev.message.content;
                        if (typeof ev.text === 'string') out += ev.text;
                    } catch (e) { /* ignore malformed lines */ }
                }
                if (out) {
                    // First-turn success: return envelope so Swift can cache
                    // the conversation IDs for follow-ups.
                    return JSON.stringify({_throttle_ok: true, conv: convId, org: orgId, text: out});
                }
                // Diagnostic: completion returned 2xx but body empty. Probe
                // /usage so Swift knows WHICH window is actually constraining
                // the user — hardcoding "5h" was wrong when the real squeeze
                // came from the 7-day window.
                var ct = '';
                try { ct = compX.getResponseHeader('content-type') || ''; } catch (e2) {}
                var usage = '';
                try {
                    var uX = new XMLHttpRequest();
                    uX.open('GET', '/api/organizations/' + orgId + '/usage', false);
                    uX.setRequestHeader('Accept', 'application/json');
                    uX.send();
                    if (uX.status < 400) {
                        var u = JSON.parse(uX.responseText);
                        var fields = ['five_hour','seven_day','seven_day_sonnet','seven_day_opus','seven_day_oauth_apps'];
                        for (var fi = 0; fi < fields.length; fi++) {
                            var f = fields[fi];
                            var w = u && u[f];
                            if (w && typeof w.utilization === 'number') {
                                // claude.ai already returns utilization in
                                // percent (e.g. 21 = 21%), NOT as a 0-1
                                // ratio. Don't re-multiply or you get the
                                // famous "2100%" bug from v2.6.1.
                                usage += f + '=' + Math.round(w.utilization);
                                if (w.resets_at) usage += '@' + w.resets_at;
                                usage += ' ';
                            }
                        }
                    }
                } catch(e3) {}
                return JSON.stringify({
                    _throttle_status: -2,
                    _err: 'empty stream status=' + compX.status + ' ct=' + ct + ' rawLen=' + raw.length + ' reused=' + (reuseConv ? '1' : '0') + ' usage=[' + usage.trim() + ']'
                });
            } catch (e) {
                return JSON.stringify({_throttle_status: -1, _err: String(e)});
            }
        })()
        """
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
