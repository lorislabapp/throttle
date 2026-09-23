import CryptoKit
import Darwin
import Foundation

struct RemoteTransferRecord: Codable, Equatable, Sendable, Identifiable {
    enum Phase: String, Codable, Sendable { case prepared, remote, stopped, returned }

    let contractVersion: Int
    let id: String
    let endpoint: String
    let serverID: String
    let runtime: String
    let nativeSessionID: String
    let projectName: String
    let localCwd: String
    let remoteCwd: String
    let localTranscriptPath: String
    let baselineSHA256: String
    let repoSHA256: String
    let baselineGitTree: String
    let nativeFilename: String
    let createdAt: Date
    var phase: Phase
    var returnedSHA256: String?

    var holdsLocalWriter: Bool { phase != .returned }
}

/// Durable authority for a local-to-remote handoff, independent of the window's
/// saved tabs. An unreadable journal is an unresolved handoff, never permission
/// to launch another writer. No credentials are stored here.
@MainActor
struct RemoteTransferJournal {
    static let shared = Self(root: URL.applicationSupportDirectory
        .appendingPathComponent("Throttle/RemoteTransfers", isDirectory: true))
    let root: URL

    enum Failure: Error, LocalizedError {
        case invalidRecord, duplicateWriter, durability(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidRecord: "The remote transfer journal needs recovery. Local resume remains suspended."
            case .duplicateWriter: "This native session already has an unresolved remote transfer."
            case .durability: "The remote transfer could not be saved durably. No remote start was requested."
            }
        }
    }

    func records() throws -> [RemoteTransferRecord] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                .filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return []
        }
        guard files.count <= 4096 else { throw Failure.invalidRecord }
        return try files.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 32_768 else { throw Failure.invalidRecord }
            let record = try JSONDecoder().decode(RemoteTransferRecord.self, from: Data(contentsOf: url))
            try validate(record)
            guard url.deletingPathExtension().lastPathComponent == record.id else { throw Failure.invalidRecord }
            return record
        }
    }

    func outstanding(runtime: String, nativeID: String) throws -> RemoteTransferRecord? {
        let matches = try records().filter {
            $0.holdsLocalWriter && $0.runtime == runtime
                && $0.nativeSessionID.caseInsensitiveCompare(nativeID) == .orderedSame
        }
        guard matches.count <= 1 else { throw Failure.invalidRecord }
        return matches.first
    }

    func begin(_ record: RemoteTransferRecord) throws {
        try validate(record)
        guard record.phase == .prepared,
              try outstanding(runtime: record.runtime, nativeID: record.nativeSessionID) == nil,
              !FileManager.default.fileExists(atPath: file(record.id).path) else { throw Failure.duplicateWriter }
        try save(record)
    }

    func update(_ record: RemoteTransferRecord) throws {
        guard let previous = try records().first(where: { $0.id == record.id }) else { throw Failure.invalidRecord }
        var comparable = record
        comparable.phase = previous.phase
        comparable.returnedSHA256 = previous.returnedSHA256
        guard comparable == previous, previous.holdsLocalWriter || record == previous else {
            throw Failure.invalidRecord
        }
        let allowed: [RemoteTransferRecord.Phase: Set<RemoteTransferRecord.Phase>] = [
            .prepared: [.prepared, .remote, .stopped], .remote: [.remote, .stopped],
            .stopped: [.stopped, .returned], .returned: [.returned]
        ]
        guard allowed[previous.phase]?.contains(record.phase) == true else { throw Failure.invalidRecord }
        try save(record)
    }

    private func file(_ id: String) -> URL { root.appendingPathComponent(id + ".json") }

    private func validate(_ record: RemoteTransferRecord) throws {
        guard record.contractVersion == 2, UUID(uuidString: record.id)?.uuidString.lowercased() == record.id,
            UUID(uuidString: record.nativeSessionID) != nil, UUID(uuidString: record.serverID) != nil,
            ["claude", "codex"].contains(record.runtime),
              record.localCwd.hasPrefix("/"), record.remoteCwd.hasPrefix("/"),
              record.localTranscriptPath.hasPrefix("/"),
              record.baselineSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              record.repoSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              record.baselineGitTree.range(of: "^[a-f0-9]{40,64}$", options: .regularExpression) != nil,
              URL(fileURLWithPath: record.nativeFilename).lastPathComponent == record.nativeFilename,
              record.returnedSHA256.map({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) ?? true,
              record.phase != .returned || record.returnedSHA256 != nil else { throw Failure.invalidRecord }
    }

    private func save(_ record: RemoteTransferRecord) throws {
        try validate(record)
        try ensureDirectory(root)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 32_768 else { throw Failure.invalidRecord }
        let url = file(record.id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(root)
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw Failure.invalidRecord }
            return
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            let parent = url.deletingLastPathComponent()
            guard parent != url else { throw Failure.invalidRecord }
            try ensureDirectory(parent)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try synchronizeDirectory(parent)
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw Failure.durability(errno) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.durability(errno) }
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 256 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
