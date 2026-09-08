import Foundation

/// A transfer is bound to both the endpoint and the server's durable identity.
/// A dropped response leaves ownership unresolved; HTTP errors are never an
/// instruction to resume the local writer.
public enum EdgeTransferService {
    public struct Capabilities: Decodable, Sendable {
        public let contractVersion: Int
        public let serverID: String
        public let workspaceRoot: String
        public let ready: Bool
    }

    public struct Input: Codable, Equatable, Sendable {
        public let id: String
        public let runtime: String
        public let nativeSessionID: String
        public let sourceCwd: String
        public let remoteCwd: String
        public let filename: String
        public let baselineSHA256: String
        public let project: String

        public init(id: String, runtime: String, nativeSessionID: String, sourceCwd: String,
                    remoteCwd: String, filename: String, baselineSHA256: String, project: String) {
            self.id = id
            self.runtime = runtime
            self.nativeSessionID = nativeSessionID.lowercased()
            self.sourceCwd = sourceCwd
            self.remoteCwd = remoteCwd
            self.filename = runtime == "claude" ? nativeSessionID.lowercased() + ".jsonl" : filename
            self.baselineSHA256 = baselineSHA256
            self.project = project
        }
    }

    public struct StopReceipt: Decodable, Sendable {
        public let bootID: String
        public let invocationID: String?
        public let unit: String
        public let controlGroup: String
        public let activeState: String
        public let populated: Int
        public let observedAt: Double

        public func validates(id: String) -> Bool {
            UUID(uuidString: bootID) != nil
                && unit == "throttle-transfer-\(id).service"
                && controlGroup == "/system.slice/\(unit)"
                && ["inactive", "failed"].contains(activeState)
                && populated == 0 && observedAt.isFinite && observedAt > 0
                && (invocationID.map { $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil } ?? true)
        }
    }

    public struct Record: Decodable, Sendable {
        public let contractVersion: Int
        public let serverID: String
        public let id: String
        public let input: Input?
        public let phase: String
        public let stopReceipt: StopReceipt?
        public let frozen: FrozenManifest?

        public func validate(
            serverID expectedServer: String, input expectedInput: Input,
            allowMissingStoppedInput: Bool = false
        ) throws {
            guard contractVersion == 2, serverID == expectedServer, id == expectedInput.id,
                  input == expectedInput || (allowMissingStoppedInput && input == nil && phase == "stopped"),
                  ["prepared", "starting", "remote", "stopped", "frozen", "returned"].contains(phase) else {
                throw Failure.bindingChanged
            }
            if ["stopped", "frozen", "returned"].contains(phase) {
                guard stopReceipt?.validates(id: id) == true else { throw Failure.invalidStopReceipt }
            } else if stopReceipt != nil {
                throw Failure.invalidStopReceipt
            }
            if ["frozen", "returned"].contains(phase) {
                guard let frozen else { throw Failure.invalidReturn }
                try frozen.validate(id: id)
            } else if frozen != nil { throw Failure.invalidReturn }
        }
    }

    public struct Connection: Sendable {
        public let endpoint: String
        public let token: String
        public let serverID: String

        public init(endpoint: String, token: String, serverID: String) {
            self.endpoint = endpoint
            self.token = token
            self.serverID = serverID
        }
    }

    public enum Failure: Error, LocalizedError {
        case upgradeRequired, bindingChanged, invalidStopReceipt, invalidUpload, invalidReturn

        public var errorDescription: String? {
            switch self {
            case .upgradeRequired: "Update the edge agent to use verified context transfers."
            case .bindingChanged: "The remote transfer identity changed. Local resume remains suspended."
            case .invalidStopReceipt: "The remote process stop is not confirmed. Local resume remains suspended."
            case .invalidReturn: "The returned files could not be verified. Both copies remain preserved."
            case .invalidUpload: "The server did not confirm the complete transfer file."
            }
        }
    }

    public static func capabilities(endpoint: String, token: String) async throws -> Capabilities {
        let connection = Connection(endpoint: endpoint, token: token, serverID: "")
        let data = try await request(connection, path: "transfers/capabilities", method: "GET")
        let result = try JSONDecoder().decode(Capabilities.self, from: data)
        guard result.contractVersion == 2, UUID(uuidString: result.serverID) != nil,
              result.workspaceRoot.hasPrefix("/"), result.ready else { throw Failure.upgradeRequired }
        return result
    }

    public static func prepare(_ input: Input, using connection: Connection) async throws -> Record {
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any] ?? [:]
        body["serverID"] = connection.serverID
        let data = try await request(connection, path: "transfers", method: "POST",
                                     json: JSONSerialization.data(withJSONObject: body))
        return try decoded(data, connection: connection, input: input)
    }

    public static func status(_ input: Input, using connection: Connection) async throws -> Record {
        let data = try await request(connection, path: try transferPath(input.id), method: "GET")
        return try decoded(data, connection: connection, input: input, allowMissingStoppedInput: true)
    }

    public static func start(_ input: Input, using connection: Connection) async throws -> Record {
        let data = try await request(
            connection, path: try transferPath(input.id) + "/start", method: "POST", timeout: 150)
        return try decoded(data, connection: connection, input: input)
    }

    public static func stop(_ input: Input, using connection: Connection) async throws -> Record {
        let data = try await request(
            connection, path: try transferPath(input.id) + "/stop", method: "POST", timeout: 45)
        return try decoded(data, connection: connection, input: input, allowMissingStoppedInput: true)
    }

    public static func upload(
        _ file: URL, kind: String, input: Input,
        expectedSHA256: String, using connection: Connection
    ) async throws {
        guard ["transcript", "repo"].contains(kind),
            let base = EdgeAgentService.validatedBaseURL(connection.endpoint)
        else { throw EdgeAgentService.APIError.badURL }
        let url = base.appendingPathComponent(try transferPath(input.id) + "/" + kind)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"; request.timeoutInterval = 180
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.serverID, forHTTPHeaderField: "X-Throttle-Server-ID")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        try validateHTTP(response)
        struct Receipt: Decodable { let bytes: Int; let sha256: String }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.bytes == size, receipt.sha256 == expectedSHA256 else { throw Failure.invalidUpload }
    }

    static func transferPath(_ id: String) throws -> String {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.bindingChanged }
        return "transfers/" + id
    }

    static func decoded(
        _ data: Data, connection: Connection, input: Input,
        allowMissingStoppedInput: Bool = false
    ) throws -> Record {
        let result = try JSONDecoder().decode(Record.self, from: data)
        try result.validate(serverID: connection.serverID, input: input,
                            allowMissingStoppedInput: allowMissingStoppedInput)
        return result
    }

    static func request(
        _ connection: Connection, path: String, method: String,
        json: Data? = nil, timeout: TimeInterval = 15
    ) async throws -> Data {
        guard let base = EdgeAgentService.validatedBaseURL(connection.endpoint) else {
            throw EdgeAgentService.APIError.badURL
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.serverID, forHTTPHeaderField: "X-Throttle-Server-ID")
        if let json {
            request.httpBody = json; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        try validateHTTP(response)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw Failure.invalidReturn }
            data.append(byte)
        }
        return data
    }

    static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw EdgeAgentService.APIError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw EdgeAgentService.APIError.http(http.statusCode) }
    }
}
