import Foundation

/// Local command runner — run saved shell commands straight from Throttle,
/// WITHOUT a `claude` session's `!` prefix. Why it beats `!`:
///   • zero tokens — output never enters an LLM context,
///   • no session required — runs even with no `claude` open,
///   • saved + re-runnable — name a command once, run it with one tap,
///   • output stays local (copyable), never pollutes a conversation.
///
/// Commands run through the LOGIN shell (`zsh -lc`) so PATH + secrets
/// (`.zshrc` / bw-env) match what the user's own tools expect — the same
/// mechanism `MCPHealthService` uses to avoid false "command not found".
/// Output is captured and bounded; execution is off-main with a timeout.
@MainActor
@Observable
final class CommandRunnerService {
    static let shared = CommandRunnerService()

    struct SavedCommand: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var command: String
        var cwd: String?          // nil → home directory
    }

    private(set) var commands: [SavedCommand] = []
    private static let key = "throttleSavedCommands"

    /// Bounded, Sendable result of one run.
    struct RunResult: Sendable {
        let output: String
        let exitCode: Int32
        let durationMs: Int
        let truncated: Bool
        var ok: Bool { exitCode == 0 }
    }

    private init() { load() }

    // MARK: - Saved commands (persisted)

    @discardableResult
    func add(name: String, command: String, cwd: String? = nil) -> SavedCommand {
        let c = SavedCommand(name: name, command: command, cwd: cwd)
        commands.append(c)
        save()
        return c
    }

    func update(_ c: SavedCommand) {
        guard let i = commands.firstIndex(where: { $0.id == c.id }) else { return }
        commands[i] = c
        save()
    }

    func remove(_ id: UUID) {
        commands.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([SavedCommand].self, from: data) else { return }
        commands = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func run(_ c: SavedCommand) async -> RunResult {
        await Self.run(command: c.command, cwd: c.cwd)
    }

    // MARK: - Execution (off-main, bounded, timeout)

    /// Max captured output before truncation (protects the 16 GB Mac from a
    /// runaway command dumping gigabytes into memory).
    nonisolated private static let outputCap = 256 * 1024
    nonisolated private static let timeout: TimeInterval = 120

    nonisolated static func run(command: String, cwd: String?) async -> RunResult {
        let cap = outputCap
        return await withTaskGroup(of: RunResult?.self) { group in
            group.addTask {
                await Task.detached(priority: .userInitiated) { () -> RunResult in
                    let start = Date()
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    proc.arguments = ["-lc", command]
                    if let cwd, !cwd.isEmpty {
                        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }
                    let pipe = Pipe()
                    proc.standardOutput = pipe
                    proc.standardError = pipe          // merge stderr into stdout
                    proc.standardInput = FileHandle.nullDevice
                    do { try proc.run() } catch {
                        return RunResult(output: "Failed to launch: \(error.localizedDescription)",
                                         exitCode: -1, durationMs: 0, truncated: false)
                    }
                    // Drain until EOF (process exit), keeping only the first `cap` bytes.
                    var buf = Data()
                    let fh = pipe.fileHandleForReading
                    while true {
                        let chunk = fh.availableData
                        if chunk.isEmpty { break }
                        if buf.count < cap { buf.append(chunk.prefix(cap - buf.count)) }
                    }
                    proc.waitUntilExit()
                    let truncated = buf.count >= cap
                    let text = String(data: buf, encoding: .utf8) ?? ""
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    return RunResult(output: text, exitCode: proc.terminationStatus,
                                     durationMs: ms, truncated: truncated)
                }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return RunResult(output: "Timed out after \(Int(timeout))s.",
                                 exitCode: -2, durationMs: Int(timeout * 1000), truncated: false)
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? RunResult(output: "", exitCode: -1, durationMs: 0, truncated: false)
        }
    }
}
