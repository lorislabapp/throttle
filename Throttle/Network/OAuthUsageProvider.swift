import Foundation
import Security
import OSLog

/// Server-truth usage via Anthropic's OAuth endpoint — the same numbers the
/// Claude apps show, aggregated across ALL the user's machines, fetched
/// headlessly with the OAuth token Claude Code already maintains. This is the
/// primary Exact-mode path since 3.2.65; the embedded-session and Safari
/// scrapes remain as fallbacks (API shape verified live 2026-07-14):
///
///     GET https://api.anthropic.com/api/oauth/usage
///     Authorization: Bearer <claude code oauth access token>
///     anthropic-beta: oauth-2025-04-20
///
///     { "five_hour": {"utilization": 69.0, "resets_at": "…"},
///       "seven_day": {...}, "seven_day_sonnet": null,
///       "limits": [{"kind":"weekly_scoped","percent":21,
///                   "scope":{"model":{"display_name":"Fable"}}, …}], … }
///
/// Token source: Claude Code keeps live credentials in the login keychain
/// (service "Claude Code-credentials", JSON payload, ~valid 8 h and refreshed
/// by the CLI). `~/.claude/.credentials.json` is a stale mirror on modern
/// installs (observed 23 days out of date) — it's only the LAST fallback.
/// Reading the keychain item triggers a one-time macOS consent prompt
/// ("Throttle wants to access…") — expected; "Always Allow" ends it.
enum OAuthUsageProvider {

    private static let logger = Logger(subsystem: "com.lorislab.throttle", category: "OAuthUsage")

    enum ProviderError: Error {
        case noToken            // neither keychain nor file had a usable token
        case tokenExpired
        case http(Int)
        case decode
    }

    /// Fetch and map to the ExactSnapshot the whole meter pipeline already
    /// understands. Throws ProviderError; callers fall back to scraping.
    static func fetch(timeout: TimeInterval = 15) async throws -> ExactSnapshot {
        guard let creds = loadCredentials() else { throw ProviderError.noToken }
        guard creds.expiresAt > Date() else { throw ProviderError.tokenExpired }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.http(-1) }
        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
        return try decodeSnapshot(data)
    }

    // MARK: - Credentials

    private struct Credentials { let accessToken: String; let expiresAt: Date }

    private static func loadCredentials() -> Credentials? {
        if let d = keychainJSON(), let c = parse(d) { return c }
        // Legacy/stale mirror — better than nothing on old installs.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let d = try? Data(contentsOf: file), let c = parse(d) { return c }
        return nil
    }

    private static func keychainJSON() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                logger.info("keychain read status \(status) — falling back to credentials file")
            }
            return nil
        }
        return data
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let o = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = o["accessToken"] as? String, !token.isEmpty else { return nil }
        let expMs = (o["expiresAt"] as? Double) ?? 0
        return Credentials(accessToken: token, expiresAt: Date(timeIntervalSince1970: expMs / 1000))
    }

    // MARK: - Decode

    /// The OAuth shape differs from the claude.ai scrape just enough to need
    /// its own decoder: utilizations are Double, `seven_day_sonnet` is null on
    /// current plans (per-model weeklies moved into `limits[].weekly_scoped`).
    static func decodeSnapshot(_ data: Data, fetchedAt: Date = Date()) throws -> ExactSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let five = window(root["five_hour"]),
              let seven = window(root["seven_day"]) else {
            throw ProviderError.decode
        }
        // Per-model weekly (Opus/Fable/…) now lives in limits[] as weekly_scoped.
        var scoped = ExactSnapshot.Window(utilization: 0, resetsAt: nil)
        if let limits = root["limits"] as? [[String: Any]],
           let entry = limits.first(where: { ($0["kind"] as? String) == "weekly_scoped" }),
           let pct = entry["percent"] as? Double {
            scoped = ExactSnapshot.Window(utilization: Int(pct.rounded()),
                                          resetsAt: iso(entry["resets_at"] as? String))
        }
        return ExactSnapshot(fiveHour: five, sevenDay: seven, sevenDaySonnet: scoped, fetchedAt: fetchedAt)
    }

    private static func window(_ any: Any?) -> ExactSnapshot.Window? {
        guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        return ExactSnapshot.Window(utilization: Int(u.rounded()), resetsAt: iso(d["resets_at"] as? String))
    }

    private static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
