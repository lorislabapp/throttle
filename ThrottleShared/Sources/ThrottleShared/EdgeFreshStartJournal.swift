import Darwin
import Foundation

struct EdgeFreshStartJournal {
    struct Entry: Codable {
        let contractVersion: Int
        let request: EdgeFreshSessionStarter.Pending
        let resolved: Bool
        var pending: EdgeFreshSessionStarter.Pending? { resolved ? nil : request }
    }

    let root: URL
    private var file: URL { root.appendingPathComponent("request.json") }
    private var invalid: EdgeFreshSessionStarter.Failure { .invalidJournal }

    func read() throws -> Entry? {
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { return nil }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 32_768 else { throw invalid }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        guard entry.contractVersion == 1 else { throw invalid }
        try validate(entry.request)
        return entry
    }

    func save(_ request: EdgeFreshSessionStarter.Pending, resolved: Bool) throws {
        try validate(request)
        try ensureDirectory(root)
        let data = try JSONEncoder().encode(Entry(contractVersion: 1, request: request, resolved: resolved))
        guard data.count <= 32_768 else { throw invalid }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronize(root)
    }

    private func validate(_ request: EdgeFreshSessionStarter.Pending) throws {
        guard UUID(uuidString: request.requestID)?.uuidString.lowercased() == request.requestID,
              UUID(uuidString: request.serverID) != nil,
              EdgeAgentService.validatedBaseURL(request.endpoint) != nil,
              request.cwd.hasPrefix("/"), request.cwd.utf8.count <= 4096, !request.cwd.contains("\0"),
              ["claude", "codex"].contains(request.runtime), request.project.utf8.count <= 256 else { throw invalid }
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid }
        } catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) {
            let parent = url.deletingLastPathComponent()
            guard parent != url else { throw invalid }
            try ensureDirectory(parent)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try synchronize(parent)
        }
    }

    private func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw invalid }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw invalid }
    }
}

struct EdgeFreshStopped: Decodable {
    struct Receipt: Decodable {
        let unit: String
        let controlGroup: String
        let bootID: String
        let invocationID: String?
        let populated: Int
        let activeState: String
        let observedAt: Double
    }
    let contractVersion: Int
    let id: String
    let serverID: String
    let phase: String
    let stopReceipt: Receipt

    func validate(_ request: EdgeFreshSessionStarter.Pending) throws {
        let unit = "throttle-session-\(request.requestID).service"
        guard contractVersion == 1, id == request.requestID, serverID == request.serverID, phase == "stopped",
              stopReceipt.unit == unit, stopReceipt.controlGroup == "/system.slice/" + unit,
              UUID(uuidString: stopReceipt.bootID) != nil, stopReceipt.populated == 0,
              ["inactive", "failed"].contains(stopReceipt.activeState), stopReceipt.observedAt.isFinite,
              stopReceipt.observedAt > 0,
              stopReceipt.invocationID.map({ $0.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil })
                ?? true else { throw EdgeFreshSessionStarter.Failure.invalidResponse }
    }
}
