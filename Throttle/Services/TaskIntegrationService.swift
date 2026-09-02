import Foundation

enum TaskIntegrationError: Error, Equatable {
    case noWorktree(String)
    case gitFailed(String)
    /// A guard that held. Rendered to the user as-is, so each case says which one.
    case refused(Refusal)

    enum Refusal: String, Sendable {
        case dirty, behind, unverified, ungated
    }
}

struct FileChange: Sendable, Equatable {
    let path: String
    let added: Int
    let removed: Int
}

/// What a merge would do, computed without performing one.
enum Mergeability: Sendable, Equatable {
    case clean
    case conflicted([String])
    /// git is too old to answer without writing something. Saying so is better
    /// than guessing on the user's behalf.
    case unknown
}

struct Assessment: Sendable, Equatable {
    let baseSHA: String
    let taskSHA: String
    /// Commits the base has that the task branch does not — what a rebase would replay onto.
    let behindBy: Int
    let aheadBy: Int
    let isDirty: Bool
    let files: [FileChange]
    let mergeability: Mergeability

    /// The two SHAs a verification was true for. A check is green only while both
    /// still hold, so integrating one task stales every other check by itself.
    var stamp: String { "\(taskSHA)+\(baseSHA)" }
}

/// Reads a finished task's worktree, and — only on an explicit call — rebases,
/// verifies, and fast-forwards it into the base branch.
///
/// Reading never writes: `assess` computes the merge in git's object database and
/// leaves the worktree at the exact SHA the agent left it on.
enum TaskIntegrationService {

    // MARK: - Assess

    static func assess(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let base = try sha("HEAD", in: repo)
        let task = try sha("HEAD", in: worktree)

        let dirty = !git(["status", "--porcelain"], in: worktree).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let ahead = count(["rev-list", "--count", "\(base)..\(task)"], in: repo)
        let behind = count(["rev-list", "--count", "\(task)..\(base)"], in: repo)

        return Assessment(baseSHA: base, taskSHA: task,
                          behindBy: behind, aheadBy: ahead, isDirty: dirty,
                          files: numstat(base: base, task: task, in: repo),
                          mergeability: mergeability(base: base, task: task, in: repo))
    }

    static func diff(taskID: String, in repo: URL) throws -> String {
        _ = try existingWorktree(taskID, in: repo)
        let branch = try TaskWorktreeService.branchName(for: taskID)
        return git(["diff", "HEAD...\(branch)"], in: repo).output
    }

    /// `merge-tree --write-tree` writes the merged tree into the object database
    /// and nothing into the worktree or the index, so a task can be read while its
    /// agent is still looking at it. It needs git 2.38; older git gets `.unknown`
    /// rather than a guess.
    ///
    /// On conflict, real git (verified on 2.54) writes everything to stdout as
    /// `<tree OID>\n<conflicted paths>\n\n<informational messages>` — "Auto-merging
    /// …" and "CONFLICT …" lines share the stream with the path list, separated
    /// from it only by a blank line. Splitting on that blank line first keeps
    /// those messages out of the reported paths.
    private static func mergeability(base: String, task: String, in repo: URL) -> Mergeability {
        let result = git(["merge-tree", "--write-tree", "--name-only", base, task], in: repo)
        if result.ok { return .clean }
        guard let firstSection = result.output.components(separatedBy: "\n\n").first else {
            return .unknown
        }
        let lines = firstSection.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return .unknown }
        // First line is the tree OID; the rest are the conflicting paths.
        let paths = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? .unknown : .conflicted(Array(paths))
    }

    private static func numstat(base: String, task: String, in repo: URL) -> [FileChange] {
        git(["diff", "--numstat", "\(base)...\(task)"], in: repo).output
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                // "-" in place of a count means a binary file.
                return FileChange(path: String(parts[2]),
                                  added: Int(parts[0]) ?? 0,
                                  removed: Int(parts[1]) ?? 0)
            }
    }

    // MARK: - git

    private static func existingWorktree(_ taskID: String, in repo: URL) throws -> URL {
        let path = try TaskWorktreeService.path(for: taskID, in: repo)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw TaskIntegrationError.noWorktree(taskID)
        }
        return path
    }

    private static func sha(_ rev: String, in directory: URL) throws -> String {
        let result = git(["rev-parse", rev], in: directory)
        guard result.ok else { throw TaskIntegrationError.gitFailed(result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func count(_ args: [String], in directory: URL) -> Int {
        Int(git(args, in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @discardableResult
    static func git(_ args: [String], in directory: URL) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(bytes: data, encoding: .utf8) ?? "")
        } catch {
            return (false, String(describing: error))
        }
    }
}
