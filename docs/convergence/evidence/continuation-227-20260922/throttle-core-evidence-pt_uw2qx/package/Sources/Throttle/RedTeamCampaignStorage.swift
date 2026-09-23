import Darwin
import Foundation

extension RedTeamCampaignStore {
    func load(_ campaignID: UUID) throws -> RedTeamCampaignLedger {
        let url = campaignURL(campaignID)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw RedTeamCampaignError.missingCampaign }
            throw RedTeamCampaignError.unsafeStorage
        }
        defer { Darwin.close(descriptor) }
        try validate(descriptor, maximumBytes: 8 * 1_024 * 1_024)
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
        guard let data,
              let ledger = try? Self.decoder.decode(RedTeamCampaignLedger.self, from: data),
              ledger.isValid,
              confined(ledger.campaign) else {
            throw RedTeamCampaignError.invalidLedger
        }
        return ledger
    }

    func write(_ ledger: RedTeamCampaignLedger, to url: URL) throws {
        guard ledger.isValid else { throw RedTeamCampaignError.invalidLedger }
        let temporary = campaignsDirectory
            .appendingPathComponent(".campaign-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw RedTeamCampaignError.unsafeStorage }
        defer {
            Darwin.close(descriptor)
            try? files.removeItem(at: temporary)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Self.encoder.encode(ledger))
        try PlanStore.synchronize(descriptor)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw RedTeamCampaignError.writeNotDurable
        }
        try synchronizeDirectory()
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try ensureStorage()
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw RedTeamCampaignError.unsafeStorage }
        defer { Darwin.close(descriptor) }
        try validate(descriptor, maximumBytes: 64 * 1_024)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw RedTeamCampaignError.unsafeStorage
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw RedTeamCampaignError.mutationBusy
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func ensureStorage() throws {
        try ensureDirectory(projectRoot.appendingPathComponent(".throttle", isDirectory: true))
        try ensureDirectory(projectRoot.appendingPathComponent(".throttle/red-team", isDirectory: true))
        try ensureDirectory(campaignsDirectory)
    }

    private func ensureDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, Darwin.mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
                throw RedTeamCampaignError.unsafeStorage
            }
        }
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.chmod(url.path, 0o700) == 0 else {
            throw RedTeamCampaignError.unsafeStorage
        }
    }

    private func validate(_ descriptor: Int32, maximumBytes: Int) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              info.st_size <= Int64(maximumBytes) else {
            throw RedTeamCampaignError.unsafeStorage
        }
    }

    private func synchronizeDirectory() throws {
        let descriptor = Darwin.open(
            campaignsDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw RedTeamCampaignError.writeNotDurable }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else {
            throw RedTeamCampaignError.writeNotDurable
        }
    }

    var campaignsDirectory: URL {
        projectRoot.appendingPathComponent(".throttle/red-team/campaigns", isDirectory: true)
    }

    private var lockURL: URL {
        projectRoot.appendingPathComponent(".throttle/red-team/mutation.lock")
    }

    func campaignURL(_ id: UUID) -> URL {
        campaignsDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
