import Foundation

extension EdgeAgentService {

    // MARK: Runtime API client (talks to an already-deployed agent)

    public enum APIError: Error, LocalizedError {
        case badURL, http(Int), decode
        public var errorDescription: String? {
            switch self {
            case .badURL: return "That host or port doesn't look right."
            case .http(401), .http(403): return "The agent rejected the token — re-copy it from the Mac's Edge sheet."
            case .http(404): return "The agent is up but that session no longer exists."
            case .http(let code) where code >= 500: return "The agent hit an error (HTTP \(code)). Check it on the box."
            case .http(let code): return "The agent returned HTTP \(code)."
            case .decode: return "The agent replied in a form Throttle couldn't read — version mismatch?"
            }
        }
    }

    // MARK: In-app Claude OAuth on the box (agent ≥0.4.0)

    public struct HealthInfo: Decodable, Sendable {
        public let ok: Bool
        public let version: String?
        public let claudeAuth: Bool?
        public let sessions: Int?
    }

    public static func health(baseURL: String, timeout: TimeInterval = 10) async throws -> HealthInfo {
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent("health") else { throw APIError.badURL }
        var r = URLRequest(url: url); r.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let h = try? JSONDecoder().decode(HealthInfo.self, from: data) else { throw APIError.decode }
        return h
    }

    public struct AuthPeek: Decodable, Sendable {
        public let running: Bool
        public let url: String?
        public let done: Bool
    }

    public static func authStart(baseURL: String, token: String) async throws {
        _ = try await request(baseURL, "auth/start", method: "POST", token: token)
    }

    public static func authPeek(baseURL: String, token: String) async throws -> AuthPeek {
        let (data, _) = try await request(baseURL, "auth/peek", method: "GET", token: token)
        guard let p = try? JSONDecoder().decode(AuthPeek.self, from: data) else { throw APIError.decode }
        return p
    }

    public static func authSubmit(baseURL: String, token: String, code: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        _ = try await request(baseURL, "auth/submit", method: "POST", token: token, json: body)
    }

    /// A capability the box asked this Mac to perform on its behalf. The request
    /// names what it wants — `build`, `test` — never how to do it; the mapping
    /// from name to command lives on the Mac, which is the whole security model.
    public struct CapabilityRequest: Decodable, Sendable, Identifiable {
        public let id: String
        public let capability: String
        public let repo: String
        public let args: [String: String]?
        public let session: String?
    }

    public static func pendingCapabilities(
        baseURL: String, token: String,
        timeout: TimeInterval = 15
    ) async throws -> [CapabilityRequest] {
        let (data, _) = try await request(baseURL, "capabilities/pending", method: "GET",
                                          token: token, timeout: timeout)
        struct Wrap: Decodable { let requests: [CapabilityRequest] }
        guard let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { throw APIError.decode }
        return wrap.requests
    }

    public static func completeCapability(
        baseURL: String, token: String, id: String,
        exitCode: Int32?, output: String, error: String?,
        timeout: TimeInterval = 30
    ) async throws {
        var body: [String: Any] = ["output": output]
        if let exitCode { body["exitCode"] = Int(exitCode) }
        if let error { body["error"] = error }
        let json = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(baseURL, "capabilities/\(id)/result", method: "POST",
                              token: token, json: json, timeout: timeout)
    }

    public static func sessions(baseURL: String, token: String, timeout: TimeInterval = 15) async throws
        -> [RemoteSession] {
        let (data, _) = try await request(baseURL, "sessions", method: "GET", token: token, timeout: timeout)
        struct Wrap: Decodable { let sessions: [RemoteSession] }
        guard let wrap = try? JSONDecoder().decode(Wrap.self, from: data) else { throw APIError.decode }
        return wrap.sessions
    }

    @discardableResult
    public static func start(
        baseURL: String, token: String, project: String?, cwd: String,
        resume: String? = nil, runtime: String? = nil
    ) async throws -> String {
        guard resume == nil else { throw EdgeFreshSessionStarter.Failure.unsupportedResume }
        return try await EdgeFreshSessionStarter.shared.start(endpoint: baseURL, token: token,
            cwd: cwd, runtime: runtime ?? "claude", project: project)
    }

    public static func action(baseURL: String, token: String, id: String, action: String) async throws {
        _ = try await request(baseURL, "sessions/\(id)/\(action)", method: "POST", token: token)
    }

    /// Attach a keystroke-streaming ttyd instance to session `id`. Returns the ttyd
    /// port + WS path — retargeting kills any previously attached session on the
    /// agent side (see `throttle-agent.mjs`'s single-attach model).
    public static func attach(baseURL: String, token: String, id: String) async throws -> (port: Int, path: String) {
        let (data, _) = try await request(baseURL, "sessions/\(id)/attach", method: "POST", token: token)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int, let path = obj["path"] as? String else { throw APIError.decode }
        return (port, path)
    }

    static func request(
        _ baseURL: String, _ path: String, method: String, token: String,
        json: Data? = nil, timeout: TimeInterval = 15
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = validatedBaseURL(baseURL)?.appendingPathComponent(path) else { throw APIError.badURL }
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json { r.httpBody = json; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return (data, http)
    }
}
