import Darwin
import Foundation

extension PlanMCPAuthority {
    /// Writes a private, durable marker next to the descriptor. Repeated calls
    /// return the same receipt; a different request cannot rewrite history.
    @discardableResult
    static func revoke(
        descriptorURL: URL,
        by actor: String,
        reason: String,
        now: Date = Date()
    ) throws -> RevocationReceipt {
        guard nonempty(actor), nonempty(reason) else {
            throw Failure.malformed("revocation_fields")
        }
        let environment = [environmentKey: descriptorURL.path]
        let authority: PlanMCPAuthority
        switch load(environment: environment, now: now) {
        case .success(let value?): authority = value
        case .failure(.revoked):
            return try readRevocationReceipt(descriptorURL: descriptorURL)
        case .success(nil): throw Failure.malformed("empty_authority")
        case .failure(let failure): throw failure
        }
        let receipt = RevocationReceipt(
            grantID: authority.grantID,
            missionID: authority.missionID,
            taskID: authority.taskID,
            revokedAt: now,
            revokedBy: actor,
            reason: reason
        )
        let directory = revocationDirectory(descriptorURL)
        try ensurePrivateDirectory(directory)
        let url = revocationURL(authority.grantID, descriptorURL: descriptorURL)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        if descriptor < 0 {
            if errno == EEXIST { return try readRevocationReceipt(descriptorURL: descriptorURL) }
            throw Failure.unsafe(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: try encoder.encode(receipt))
            try PlanStore.synchronize(descriptor)
            try handle.close()
            try synchronizeDirectory(directory)
        } catch {
            throw Failure.unsafe(url.path)
        }
        return receipt
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func readPrivateFile(_ url: URL) -> Result<Data, Failure> {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(.unreadable(url.path)) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_size <= 64 * 1_024 else {
            return .failure(.unsafe(url.path))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 64 * 1_024 + 1),
              data.count <= 64 * 1_024, data.count == info.st_size else {
            return .failure(.unreadable(url.path))
        }
        return .success(data)
    }

    static func revocationStatus(
        for grantID: UUID,
        descriptorURL: URL
    ) -> Result<Bool, Failure> {
        let url = revocationURL(grantID, descriptorURL: descriptorURL)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            return errno == ENOENT ? .success(false) : .failure(.unreadable(url.path))
        }
        switch readPrivateFile(url) {
        case .success: return .success(true)
        case .failure(let failure): return .failure(failure)
        }
    }

    private static func readRevocationReceipt(
        descriptorURL: URL
    ) throws -> RevocationReceipt {
        let authority: PlanMCPAuthority
        switch readPrivateFile(descriptorURL) {
        case .failure(let failure): throw failure
        case .success(let data):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(PlanMCPAuthority.self, from: data),
                  decoded.schemaVersion == currentSchemaVersion else {
                throw Failure.malformed("undecodable")
            }
            authority = decoded
        }
        let url = revocationURL(authority.grantID, descriptorURL: descriptorURL)
        let data = try readPrivateFile(url).get()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(RevocationReceipt.self, from: data),
              receipt.schemaVersion == 1,
              receipt.grantID == authority.grantID,
              receipt.missionID == authority.missionID,
              receipt.taskID == authority.taskID,
              nonempty(receipt.revokedBy),
              nonempty(receipt.reason) else {
            throw Failure.malformed("revocation_receipt")
        }
        return receipt
    }

    private static func revocationDirectory(_ descriptorURL: URL) -> URL {
        descriptorURL.deletingLastPathComponent()
            .appendingPathComponent("revocations", isDirectory: true)
    }

    private static func revocationURL(_ grantID: UUID, descriptorURL: URL) -> URL {
        revocationDirectory(descriptorURL)
            .appendingPathComponent(grantID.uuidString + ".json")
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let creationResult = Darwin.mkdir(url.path, 0o700)
        let created = creationResult == 0
        if creationResult != 0, errno != EEXIST { throw Failure.unsafe(url.path) }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw Failure.unsafe(url.path)
        }
        if created { try synchronizeDirectory(url.deletingLastPathComponent()) }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw Failure.unsafe(url.path) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw Failure.unsafe(url.path)
        }
    }
}
