import Foundation

/// One Claude Code OTel log record Traycer attributes cost to, flattened from
/// the OTLP/JSON `ExportLogsServiceRequest` body.
struct TraycerEvent: Equatable {
    let sessionId: String        // session.id — the join key to usage_events
    let eventName: String        // skill_activated / tool_result / tool_decision
    let sequence: Int            // event.sequence — per-session monotonic; dedup key
    let tsUnixSeconds: Int
    var toolName: String?         // tool_result / tool_decision
    var skillName: String?        // skill_activated (skill.name) or parsed Skill tool_input
    var skillSource: String?      // skill_activated (skill.source)
    var fullCommand: String?      // Bash tool_result: tool_input.full_command
    var decision: String?         // tool_decision
    var success: Bool?            // tool_result
}

/// Decodes Claude Code's OTLP/HTTP **JSON** logs export (emitted when
/// `OTEL_EXPORTER_OTLP_PROTOCOL=http/json` — verified against v2.1.202). Chosen
/// over protobuf because Claude Code emits clean JSON, so no `swift-protobuf`
/// dependency and no hand-rolled wire decoder is needed.
///
/// Fail-open by construction: a malformed root, record, or `tool_input` blob is
/// skipped, never thrown. **Never reads the `prompt` attribute** (privacy — we
/// don't enable `OTEL_LOG_USER_PROMPTS`, and even if present we ignore it).
enum TraycerDecoder {

    /// Event types we keep. Everything else (api_request, mcp_server_connection,
    /// hook_*, user_prompt, …) is dropped — we only attribute cost to skills,
    /// tool results, and permission decisions.
    static let kept: Set<String> = ["skill_activated", "tool_result", "tool_decision"]

    static func decodeLogs(_ data: Data) -> [TraycerEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [TraycerEvent] = []
        for rl in root["resourceLogs"] as? [[String: Any]] ?? [] {
            for sl in rl["scopeLogs"] as? [[String: Any]] ?? [] {
                for lr in sl["logRecords"] as? [[String: Any]] ?? [] {
                    if let e = event(from: lr) { out.append(e) }
                }
            }
        }
        return out
    }

    private static func event(from lr: [String: Any]) -> TraycerEvent? {
        let a = flatten(lr["attributes"] as? [[String: Any]] ?? [])
        guard let session = a["session.id"] as? String, !session.isEmpty,
              let name = a["event.name"] as? String, kept.contains(name) else { return nil }

        // Canonical epoch seconds from the OTLP logRecord's timeUnixNano.
        // (`event.timestamp` is an ISO-8601 STRING, not usable as an int.)
        let ts = nanoToSeconds(lr["timeUnixNano"]) ?? 0
        let seq = intVal(a["event.sequence"]) ?? 0
        var ev = TraycerEvent(sessionId: session, eventName: name, sequence: seq, tsUnixSeconds: ts)
        ev.toolName = a["tool_name"] as? String
        ev.skillName = a["skill.name"] as? String
        ev.skillSource = a["skill.source"] as? String
        ev.decision = a["decision"] as? String
        ev.success = boolVal(a["success"])

        // full_command (Bash) and the invoked skill live inside the tool_input JSON string.
        if let ti = a["tool_input"] as? String, let d = ti.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ev.fullCommand = obj["full_command"] as? String ?? obj["command"] as? String
            if ev.skillName == nil { ev.skillName = obj["skill"] as? String }
        }
        return ev
    }

    /// OTLP attribute list `[{key, value:{stringValue|intValue|boolValue|doubleValue}}]`
    /// → `[key: scalar]`. Per OTLP/JSON, int64 arrives as a STRING (`"intValue":"123"`).
    private static func flatten(_ list: [[String: Any]]) -> [String: Any] {
        var d: [String: Any] = [:]
        for item in list {
            guard let k = item["key"] as? String, let v = item["value"] as? [String: Any] else { continue }
            if let s = v["stringValue"] { d[k] = s }
            else if let i = v["intValue"] { d[k] = i }
            else if let b = v["boolValue"] { d[k] = b }
            else if let n = v["doubleValue"] { d[k] = n }
        }
        return d
    }

    private static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }
    private static func boolVal(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" }
        return nil
    }
    private static func nanoToSeconds(_ v: Any?) -> Int? {
        if let s = v as? String, let n = Int(s) { return n / 1_000_000_000 }
        if let n = v as? Int { return n / 1_000_000_000 }
        return nil
    }
}
