import Foundation

/// One durable, unresolved creation per client. A retry replays its exact identity;
/// the journal is shared by the Mac and iOS API paths, without storing credentials.
public actor EdgeFreshSessionStarter {
    public static let shared = EdgeFreshSessionStarter(root: URL.applicationSupportDirectory
        .appendingPathComponent("Throttle/RemoteStarts", isDirectory: true))

    public struct Pending: Codable, Equatable, Sendable {
        public let requestID: String
        public let serverID: String
        public let endpoint: String
        public let cwd: String
        public let runtime: String
        public let project: String
    }

    public enum Failure: Error, LocalizedError {
        case busy, unresolved, invalidResponse, invalidJournal, unsupportedResume

        public var errorDescription: String? {
            switch self {
            case .busy: "A server start is already being checked."
            case .unresolved: "Resolve the saved server start before creating another conversation."
            case .invalidResponse: "The server start is unconfirmed. Its saved request will be reused."
            case .invalidJournal: "The saved server start needs recovery. No new start was sent."
            case .unsupportedResume: "An existing conversation must use its verified transfer or session controls."
            }
        }
    }

    private let journal: EdgeFreshStartJournal
    private let session: URLSession
    private var busy = false

    public init(root: URL, session: URLSession = .shared) {
        journal = EdgeFreshStartJournal(root: root)
        self.session = session
    }

    public func pending() throws -> Pending? { try journal.read()?.pending }

    public func start(endpoint: String, token: String, cwd: String,
                      runtime: String = "claude", project: String? = nil) async throws -> String {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        let name = project ?? URL(fileURLWithPath: cwd).lastPathComponent
        let request: Pending
        if let saved = try pending() {
            guard saved.endpoint == endpoint, saved.cwd == cwd, saved.runtime == runtime,
                  saved.project == name else { throw Failure.unresolved }
            request = saved
        } else {
            let data = try await send(endpoint, path: "sessions/capabilities", token: token)
            struct Capabilities: Decodable { let contractVersion: Int; let serverID: String }
            let capabilities = try JSONDecoder().decode(Capabilities.self, from: data)
            guard capabilities.contractVersion == 1, UUID(uuidString: capabilities.serverID) != nil else {
                throw Failure.invalidResponse
            }
            request = Pending(requestID: UUID().uuidString.lowercased(), serverID: capabilities.serverID,
                              endpoint: endpoint, cwd: cwd, runtime: runtime, project: name)
            try journal.save(request, resolved: false)
        }
        return try await submit(request, token: token)
    }

    public func retry(endpoint: String, token: String) async throws -> String {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        guard let request = try pending(), request.endpoint == endpoint else { throw Failure.unresolved }
        return try await submit(request, token: token)
    }

    public func stopPending(endpoint: String, token: String) async throws {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        guard let request = try pending(), request.endpoint == endpoint else { throw Failure.unresolved }
        let data = try await send(endpoint, path: "sessions/fresh-\(request.requestID)/stop", token: token,
                                  body: JSONEncoder().encode(request))
        let stopped = try JSONDecoder().decode(EdgeFreshStopped.self, from: data)
        try stopped.validate(request)
        try journal.save(request, resolved: true)
    }

    private func submit(_ request: Pending, token: String) async throws -> String {
        let data = try await send(request.endpoint, path: "sessions", token: token,
                                  body: JSONEncoder().encode(request))
        struct Response: Decodable {
            let id: String; let serverID: String; let cwd: String
            let project: String; let runtime: String; let state: String
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.id == "fresh-" + request.requestID, response.serverID == request.serverID,
              response.cwd == request.cwd, response.runtime == request.runtime,
              response.project == request.project, response.state == "remote" else { throw Failure.invalidResponse }
        try journal.save(request, resolved: true)
        return response.id
    }

    private func send(_ endpoint: String, path: String, token: String, body: Data? = nil) async throws -> Data {
        guard let url = EdgeAgentService.validatedBaseURL(endpoint)?.appendingPathComponent(path) else {
            throw EdgeAgentService.APIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 150
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32_768 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
