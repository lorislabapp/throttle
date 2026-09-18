import Foundation

/// Every Claude Code session this machine knows about, as Claude Code itself
/// lists them — background agents, interactive sessions, and the cloud threads a
/// redesigned Project spawns, which carry their own `kind`.
///
/// Throttle used to see only the sessions it opened, so an agent that blocked or
/// failed in a background session waited unseen. Reading the CLI's own inventory
/// keeps that honest without guessing at private state.
enum ClaudeAgentInventory {

    struct Session: Equatable, Sendable, Identifiable {
        let id: String
        let sessionID: String?
        let name: String?
        let cwd: String?
        let kind: String
        let state: String?
        let startedAt: Date?

        /// An interactive session Throttle opened is already on screen; these are
        /// the ones that exist elsewhere.
        var isBackgroundOrCloud: Bool { kind != "interactive" }
        var needsAttention: Bool { ["blocked", "failed"].contains(state ?? "") }
    }

    enum InventoryError: Error, Equatable { case unavailable }

    static let executableCandidates = [
        "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path
    ]

    static func executable(_ fileManager: FileManager = .default) -> String? {
        executableCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Parses `claude agents --json`. Unknown fields are ignored and a malformed
    /// entry is dropped: an inventory that throws on one bad row shows nothing.
    static func parse(_ data: Data) -> [Session] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
            let started = (row["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) }
            return Session(id: id, sessionID: row["sessionId"] as? String, name: row["name"] as? String,
                           cwd: row["cwd"] as? String, kind: kind, state: row["state"] as? String,
                           startedAt: started)
        }
    }

    /// Runs the CLI with a deadline; a hung or missing binary returns nothing
    /// rather than blocking the Cockpit's refresh. Completed sessions are left
    /// out — `--all` would add them back, and a card about what still waits on
    /// you must not fill with agents that stopped months ago.
    static func load(timeout: TimeInterval = 6) async -> [Session] {
        guard let executable = executable() else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["agents", "--json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: [])
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? parse(data) : [])
            }
        }
    }
}
