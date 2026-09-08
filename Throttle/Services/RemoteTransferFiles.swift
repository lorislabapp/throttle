import Darwin
import Foundation

/// Publish complete metadata without replacing another attempt's destination.
/// A crash during staging leaves only an unreferenced temporary file.
enum RemoteTransferFiles {
    static func publish(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID()).pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try synchronize(temporary)
        guard link(temporary.path, destination.path) == 0 else { throw RemoteTransferReturn.Failure.invalidArtifact }
        try synchronize(destination.deletingLastPathComponent())
    }

    static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw RemoteTransferReturn.Failure.invalidArtifact }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RemoteTransferReturn.Failure.invalidArtifact }
    }
}
