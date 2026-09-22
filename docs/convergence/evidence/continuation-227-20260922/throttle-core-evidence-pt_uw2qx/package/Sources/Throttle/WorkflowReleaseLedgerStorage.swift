import CryptoKit
import Darwin
import Foundation

extension WorkflowReleaseLedgerStore {
    typealias LedgerContents = (
        events: [WorkflowReleaseLedgerEvent],
        lines: [Data]
    )

    func withLedger<T>(
        _ releaseID: String,
        body: (Int32, [WorkflowReleaseLedgerEvent], [Data]) throws -> T
    ) throws -> T {
        guard Self.safeID(releaseID) else { throw WorkflowReleaseLedgerError.invalidManifest }
        processLock.lock()
        defer { processLock.unlock() }
        try ensureStorage()
        let url = ledgerURL(releaseID)
        var created = false
        var descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw WorkflowReleaseLedgerError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        try validate(descriptor)
        if created { try synchronizeDirectory(releaseDirectory) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw WorkflowReleaseLedgerError.unsafeStorage
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkflowReleaseLedgerError.busy
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { flock(descriptor, LOCK_UN) }
        let contents = try read(descriptor)
        return try body(descriptor, contents.events, contents.lines)
    }

    func read(_ descriptor: Int32) throws -> LedgerContents {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw WorkflowReleaseLedgerError.unsafeStorage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            throw WorkflowReleaseLedgerError.corruptLedger
        }
        guard data.count <= 8 * 1_024 * 1_024 else { throw WorkflowReleaseLedgerError.corruptLedger }
        if data.isEmpty { return ([], []) }
        guard data.last == 0x0A else { throw WorkflowReleaseLedgerError.corruptLedger }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().map(Data.init)
        guard !lines.contains(where: { $0.isEmpty || $0.count > 1 * 1_024 * 1_024 }) else {
            throw WorkflowReleaseLedgerError.corruptLedger
        }
        let events = try lines.enumerated().map { index, line in
            guard let event = try? Self.decoder.decode(WorkflowReleaseLedgerEvent.self, from: line),
                  event.isValid,
                  event.sequence == index + 1,
                  event.previousDigest == (index == 0 ? nil : Self.sha256(lines[index - 1])) else {
                throw WorkflowReleaseLedgerError.corruptLedger
            }
            return event
        }
        guard Set(events.map(\.eventID)).count == events.count else {
            throw WorkflowReleaseLedgerError.corruptLedger
        }
        return (events, lines)
    }

    func appendLine(_ data: Data, descriptor: Int32) throws {
        let bytes = data + Data([0x0A])
        let result = bytes.withUnsafeBytes { pointer -> Bool in
            guard let base = pointer.baseAddress else { return false }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count > 0 { written += count; continue }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        guard result else { throw WorkflowReleaseLedgerError.unsafeStorage }
        let synchronized = fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
        guard synchronized else {
            throw WorkflowReleaseLedgerError.unsafeStorage
        }
    }

    private func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw WorkflowReleaseLedgerError.unsafeStorage
        }
    }

    private func ensureStorage() throws {
        try ensureDirectory(projectRoot.appendingPathComponent(".throttle", isDirectory: true))
        try ensureDirectory(releaseDirectory)
    }

    private func ensureDirectory(_ url: URL) throws {
        var info = stat()
        var created = false
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, Darwin.mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw WorkflowReleaseLedgerError.unsafeStorage
            }
            created = errno != EEXIST
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.chmod(url.path, 0o700) == 0 else {
            throw WorkflowReleaseLedgerError.unsafeStorage
        }
        if created { try synchronizeDirectory(url.deletingLastPathComponent()) }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw WorkflowReleaseLedgerError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw WorkflowReleaseLedgerError.unsafeStorage
        }
    }

    private var releaseDirectory: URL {
        projectRoot.appendingPathComponent(".throttle/releases", isDirectory: true)
    }

    private func ledgerURL(_ releaseID: String) -> URL {
        releaseDirectory.appendingPathComponent(releaseID + ".ndjson")
    }

    static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
