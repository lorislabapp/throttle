import Foundation

/// Writes only the already-reviewed typed report. No database, log or provider
/// access is permitted here; the archive must match the preview byte-for-byte.
enum DiagnosticArchive {
    enum Failure: Error { case invalidDirectory, unexpectedFiles, archiveFailed }

    static func write(_ report: DiagnosticReport, to destination: URL,
                      temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let files = FileManager.default
        for directory in [destination, temporaryRoot] {
            guard directory.isFileURL,
                  try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw Failure.invalidDirectory
            }
        }
        let stage = temporaryRoot.appendingPathComponent("throttle-diagnostics-\(UUID().uuidString)")
        try files.createDirectory(at: stage, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        // Only this invocation's newly created staging directory is removed.
        defer { try? files.removeItem(at: stage) }
        let payload = stage.appendingPathComponent("report", isDirectory: true)
        try files.createDirectory(at: payload, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        let summary = payload.appendingPathComponent("summary.txt")
        try Data(report.text.utf8).write(to: summary, options: .withoutOverwriting)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summary.path)
        guard Set(try files.contentsOfDirectory(atPath: payload.path)) == DiagnosticReport.exportedFiles else {
            throw Failure.unexpectedFiles
        }
        let archive = stage.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", payload.path, archive.path]
        // Do not send filesystem paths or archive failures to the app's log.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.archiveFailed }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let output = destination.appendingPathComponent("\(stage.lastPathComponent).zip")
        // copyItem refuses an existing target; an earlier export is never replaced.
        try files.copyItem(at: archive, to: output)
        return output
    }
}
