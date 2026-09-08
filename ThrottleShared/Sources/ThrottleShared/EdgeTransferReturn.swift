import CryptoKit
import Foundation

extension EdgeTransferService {
    public struct Artifact: Codable, Equatable, Sendable {
        public let bytes: Int
        public let sha256: String

        public func validate() throws {
            guard bytes > 0, bytes <= 128 * 1024 * 1024,
                  sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw Failure.invalidReturn
            }
        }
    }

    public struct FrozenManifest: Codable, Equatable, Sendable {
        public let attempt: String
        public let transcript: Artifact
        public let repo: Artifact
        public let tree: String
        public let commit: String
        public let ref: String

        public func validate(id: String) throws {
            guard UUID(uuidString: id)?.uuidString.lowercased() == id,
                  attempt.hasPrefix("return-"), UUID(uuidString: String(attempt.dropFirst(7))) != nil,
                  tree.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil,
                  commit.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil,
                  ref == "refs/throttle/transfers/\(id)/return" else { throw Failure.invalidReturn }
            try transcript.validate()
            try repo.validate()
        }
    }

    public static func freeze(_ input: Input, using connection: Connection) async throws -> Record {
        let data = try await request(connection, path: try transferPath(input.id) + "/freeze",
                                     method: "POST", timeout: 180)
        let record = try decoded(data, connection: connection, input: input)
        guard ["frozen", "returned"].contains(record.phase) else { throw Failure.invalidReturn }
        return record
    }

    public static func acknowledge(
        _ input: Input, manifest: FrozenManifest,
        using connection: Connection
    ) async throws -> Record {
        try manifest.validate(id: input.id)
        let body = try JSONSerialization.data(withJSONObject: ["transcript": manifest.transcript.sha256,
                                                               "repo": manifest.repo.sha256])
        let data = try await request(connection, path: try transferPath(input.id) + "/acknowledge",
                                     method: "POST", json: body)
        let record = try decoded(data, connection: connection, input: input)
        guard record.phase == "returned", record.frozen == manifest else { throw Failure.invalidReturn }
        return record
    }

    /// Retain only a 64 KiB buffer while downloading. A partial/oversized response
    /// never becomes the returned artifact; each attempt has its own local file.
    public static func download(
        _ input: Input, kind: String, expected: Artifact, directory: URL,
        using connection: Connection, session: URLSession = .shared
    ) async throws -> URL {
        try expected.validate()
        guard ["transcript", "repo"].contains(kind),
              let base = EdgeAgentService.validatedBaseURL(connection.endpoint) else { throw Failure.invalidReturn }
        var request = URLRequest(url: base.appendingPathComponent(try transferPath(input.id) + "/" + kind))
        request.timeoutInterval = 180
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue(connection.serverID, forHTTPHeaderField: "X-Throttle-Server-ID")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try validateHTTP(response)
        guard let http = response as? HTTPURLResponse, response.expectedContentLength == Int64(expected.bytes),
            http.value(forHTTPHeaderField: "X-Throttle-SHA256") == expected.sha256
        else { throw Failure.invalidReturn }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("return-\(UUID())-\(kind)")
        try Data().write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let file = try FileHandle(forWritingTo: destination)
        var complete = false
        defer {
            try? file.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        var count = 0, buffer = Data(), hash = SHA256()
        buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            guard count < expected.bytes else { throw Failure.invalidReturn }
            count += 1; buffer.append(byte)
            if buffer.count == 65_536 {
                hash.update(data: buffer); try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
            }
        }
        hash.update(data: buffer); try file.write(contentsOf: buffer)
        guard count == expected.bytes,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected.sha256 else {
            throw Failure.invalidReturn
        }
        try file.synchronize()
        complete = true
        return destination
    }
}
