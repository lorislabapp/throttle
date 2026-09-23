import Foundation

extension ClaudeWebSessionProvider {
    // MARK: - Prompt + JS

    func composePrompt(messages: [ChatMessage], system: String) -> String {
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
    func buildPollJS() -> String {
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
    func buildStreamingJS(prompt: String, reuse: (org: String, conv: String)?) -> String {
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        let reuseOrgJS  = reuse.map { "\"\($0.org)\"" }  ?? "null"
        let reuseConvJS = reuse.map { "\"\($0.conv)\"" } ?? "null"
        return [
            streamingScriptPart1(reuseOrgJS: reuseOrgJS, reuseConvJS: reuseConvJS),
            streamingScriptPart2(escapedPrompt: escapedPrompt),
            Self.streamingScriptPart3,
            Self.streamingScriptPart4,
            Self.streamingScriptPart5
        ].joined(separator: "\n")
    }

    private func streamingScriptPart1(reuseOrgJS: String, reuseConvJS: String) -> String {
        """
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
        """
    }

    private func streamingScriptPart2(escapedPrompt: String) -> String {
        """
                    var createX = new XMLHttpRequest();
                    createX.open('POST', '/api/organizations/' + orgId + '/chat_conversations', false);
                    createX.setRequestHeader('Content-Type', 'application/json');
                    createX.setRequestHeader('Accept', 'application/json');
                    createX.setRequestHeader('anthropic-client-platform', 'web_claude_ai');
                    createX.send(JSON.stringify({uuid: convId, name: 'Throttle assistant'}));
                    if (createX.status >= 400) return JSON.stringify({_throttle_status: createX.status, _err:\
         'create:' + createX.responseText.substring(0,200)});
                }

                // Async streaming pump. Started before this function
                // returns; runs concurrently while Swift polls the
                // window globals via `buildPollJS()`.
                (async function() {
                    try {
                        var compResp = await fetch('/api/organizations/' + orgId + '/chat_conversations/' +\
         convId + '/completion', {
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
        """
    }

    private static let streamingScriptPart3 = """
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
    """

    private static let streamingScriptPart4 = """
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
                                if (ev.delta && typeof ev.delta.text === 'string') window.__throttle_buf\
     += ev.delta.text;
                                if (ev.delta && typeof ev.delta.content === 'string')\
     window.__throttle_buf += ev.delta.content;
                                if (ev.message && typeof ev.message.content === 'string')\
     window.__throttle_buf += ev.message.content;
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
    """

    private static let streamingScriptPart5 = """
                org: orgId
            });
        } catch (e) {
            return JSON.stringify({_throttle_status: -1, _err: String(e)});
        }
    })()
    """
}
