import Darwin
import Foundation

/// Owns the filesystem boundary for the budget ledger.
final class BudgetAdmissionStorage: @unchecked Sendable {
    private let projectRoot: URL
    private let processLock = NSRecursiveLock()
    private let files = FileManager.default

    init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    var ledgerExists: Bool {
        var info = stat()
        return lstat(ledgerURL.path, &info) == 0
    }

    func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try ensureStorage()
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BudgetAdmissionError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        try validateDescriptor(descriptor)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw BudgetAdmissionError.unsafeStorage
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw BudgetAdmissionError.mutationBusy
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func load() throws -> BudgetAdmissionLedger {
        let descriptor = Darwin.open(ledgerURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw BudgetAdmissionError.missingLedger }
            throw BudgetAdmissionError.unsafeStorage
        }
        defer { Darwin.close(descriptor) }
        try validateDescriptor(descriptor, maximumBytes: 8 * 1_024 * 1_024)
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
        guard let data, let ledger = try? Self.decoder.decode(BudgetAdmissionLedger.self, from: data),
              ledger.isValid else { throw BudgetAdmissionError.invalidLedger }
        return ledger
    }

    func write(_ ledger: BudgetAdmissionLedger) throws {
        guard ledger.isValid else { throw BudgetAdmissionError.invalidLedger }
        let data = try Self.encoder.encode(ledger)
        let temporary = budgetDirectory.appendingPathComponent(".ledger-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw BudgetAdmissionError.unsafeStorage }
        defer {
            Darwin.close(descriptor)
            try? files.removeItem(at: temporary)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try PlanStore.synchronize(descriptor)
        guard Darwin.rename(temporary.path, ledgerURL.path) == 0 else {
            throw BudgetAdmissionError.writeNotDurable
        }
        try synchronizeDirectory()
    }

    private var budgetDirectory: URL {
        projectRoot.appendingPathComponent(".throttle/budget", isDirectory: true)
    }

    private var throttleDirectory: URL {
        projectRoot.appendingPathComponent(".throttle", isDirectory: true)
    }

    private var ledgerURL: URL { budgetDirectory.appendingPathComponent("ledger.json") }
    private var lockURL: URL { budgetDirectory.appendingPathComponent("mutation.lock") }

    private func ensureStorage() throws {
        try ensureOwnedDirectory(throttleDirectory)
        try ensureOwnedDirectory(budgetDirectory)
    }

    private func ensureOwnedDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, Darwin.mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw BudgetAdmissionError.unsafeStorage
            }
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.chmod(url.path, 0o700) == 0 else {
            throw BudgetAdmissionError.unsafeStorage
        }
    }

    private func validateDescriptor(_ descriptor: Int32, maximumBytes: Int = 64 * 1_024) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_size <= Int64(maximumBytes) else {
            throw BudgetAdmissionError.unsafeStorage
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(budgetDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BudgetAdmissionError.writeNotDurable }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw BudgetAdmissionError.writeNotDurable
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
