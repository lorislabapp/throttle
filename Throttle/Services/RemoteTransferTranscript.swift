import Darwin
import Foundation

/// Preserve the inode actually displaced at the publication instant. A writer
/// holding that inode can still append to the recovery copy, never to discarded data.
enum RemoteTransferTranscript {
    static func exchange(
        source: URL, destination: URL, baselineSHA256: String, returnedSHA256: String,
        directory: URL, beforeSwap: () throws -> Void = {}
    ) throws {
        let id = UUID().uuidString.lowercased()
        let displaced = destination.deletingLastPathComponent().appendingPathComponent(".throttle-\(id).previous")
        let marker = directory.appendingPathComponent("displaced-transcript-\(id).json")
        var exchanged = false
        defer { if !exchanged { try? FileManager.default.removeItem(at: displaced) } }
        try FileManager.default.copyItem(at: source, to: displaced)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: displaced.path)
        try synchronize(displaced)
        guard try RemoteTransferJournal.sha256(displaced) == returnedSHA256 else {
            throw RemoteTransferReturn.Failure.invalidArtifact
        }
        let intent = ["destination": destination.path, "displaced": displaced.path,
                      "baselineSHA256": baselineSHA256, "returnedSHA256": returnedSHA256]
        try RemoteTransferFiles.publish(JSONSerialization.data(withJSONObject: intent), to: marker)
        try beforeSwap()
        guard renamex_np(displaced.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw RemoteTransferReturn.Failure.invalidArtifact
        }
        exchanged = true // Never remove the displaced inode, including on failure.
        try synchronize(destination.deletingLastPathComponent())
        guard try RemoteTransferJournal.sha256(displaced) == baselineSHA256 else {
            // Restore the displaced local inode atomically. Any concurrent changes
            // to the newly installed inode are retained at the recovery path too.
            if renamex_np(displaced.path, destination.path, UInt32(RENAME_SWAP)) == 0 {
                try synchronize(destination.deletingLastPathComponent())
            }
            throw RemoteTransferReturn.Failure.conflict(
                "The conversation changed during publication. Recovery copy: \(displaced.path).")
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw RemoteTransferReturn.Failure.invalidArtifact }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RemoteTransferReturn.Failure.invalidArtifact }
    }
}
