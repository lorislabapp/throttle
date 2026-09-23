import Foundation

extension ClaudeWebSessionProvider {
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
        return [
            legacyScriptPart1(reuseOrgJS: reuseOrgJS, reuseConvJS: reuseConvJS),
            legacyScriptPart2(escapedPrompt: escapedPrompt),
            Self.legacyScriptPart3,
            Self.legacyScriptPart4,
            Self.legacyScriptPart5
        ].joined(separator: "\n")
    }

    private func legacyScriptPart1(reuseOrgJS: String, reuseConvJS: String) -> String {
        """
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
        """
    }

    private func legacyScriptPart2(escapedPrompt: String) -> String {
        """
                    createX.send(JSON.stringify({uuid: convId, name: 'Throttle assistant'}));
                    if (createX.status >= 400) return JSON.stringify({_throttle_status: createX.status, _err:\
         'create:' + createX.responseText.substring(0,200)});
                }

                // Step 3: send completion request — sync XHR collects the
                // full SSE text. We then walk the events in JS.
                var compX = new XMLHttpRequest();
                compX.open('POST', '/api/organizations/' + orgId + '/chat_conversations/' + convId +\
         '/completion', false);
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
        """
    }

    private static let legacyScriptPart3 = """
                    }
                } catch(e) {}
                return JSON.stringify({_throttle_status: 429, _err: 'rate_limit window=' + rep + '\
     resetsAt=' + resetsAt});
            }
            if (compX.status >= 400) return JSON.stringify({_throttle_status: compX.status, _err:\
     'complete:' + compX.responseText.substring(0,200)});

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
    """

    private static let legacyScriptPart4 = """
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
                    var fields =\
     ['five_hour','seven_day','seven_day_sonnet','seven_day_opus','seven_day_oauth_apps'];
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
    """

    private static let legacyScriptPart5 = """
                }
            } catch(e3) {}
            return JSON.stringify({
                _throttle_status: -2,
                _err: 'empty stream status=' + compX.status + ' ct=' + ct + ' rawLen=' + raw.length + '\
     reused=' + (reuseConv ? '1' : '0') + ' usage=[' + usage.trim() + ']'
            });
        } catch (e) {
            return JSON.stringify({_throttle_status: -1, _err: String(e)});
        }
    })()
    """
}
