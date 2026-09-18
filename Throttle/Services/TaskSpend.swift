import Foundation
import GRDB

/// What one task actually cost, measured rather than estimated.
///
/// A task runs in its own git worktree, so every session Claude Code opened in
/// that directory belongs to it — that is the join, and it survives restarts,
/// which a live tab does not. The figure is what this Mac observed; it is never
/// added to a subscription quota or to an invoice, because those answer other
/// questions.
enum TaskSpend {

    struct Entry: Equatable, Sendable {
        let taskID: String
        let sessionIDs: [String]
        let costEUR: Double
        /// False when no session was found for the task: "not measured" is not zero.
        var measured: Bool { !sessionIDs.isEmpty }
    }

    /// The Claude Code transcript folder for a directory. Claude Code folds every
    /// character outside [A-Za-z0-9] into "-", so the name is built, never decoded.
    static func transcriptFolderName(for path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    static func worktree(for taskID: String, projectRoot: URL) -> URL {
        projectRoot.appending(path: ".claude/worktrees").appending(path: taskID)
    }

    /// Session ids whose transcripts live in the task's worktree.
    static func sessionIDs(forTask taskID: String, projectRoot: URL,
                           claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
                               .appending(path: ".claude")) -> [String] {
        let folder = claudeHome.appending(path: "projects")
            .appending(path: transcriptFolderName(for: worktree(for: taskID, projectRoot: projectRoot).path))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Cost per task, read in one pass. Tasks with no session are still returned,
    /// unmeasured, so a view can say so instead of printing zero.
    static func spend(forTasks taskIDs: [String], projectRoot: URL,
                      database: any DatabaseReader) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for taskID in taskIDs {
            let sessions = sessionIDs(forTask: taskID, projectRoot: projectRoot)
            let cost = (try? database.read { database in
                try sessions.reduce(0.0) { total, session in
                    total + (try StatsDataService.cockpitSessionCostEUR(in: database, sessionId: session))
                }
            }) ?? 0
            entries[taskID] = Entry(taskID: taskID, sessionIDs: sessions, costEUR: cost)
        }
        return entries
    }

    /// What the plan has cost so far: the sum over measured tasks, and how many
    /// tasks carry no measurement, because an average over unknowns is a lie.
    struct Total: Equatable, Sendable {
        let costEUR: Double
        let measured: Int
        let unmeasured: Int
    }

    static func total(_ entries: [String: Entry]) -> Total {
        let measured = entries.values.filter(\.measured)
        return Total(costEUR: measured.reduce(0) { $0 + $1.costEUR },
                     measured: measured.count, unmeasured: entries.count - measured.count)
    }

    static func format(_ costEUR: Double) -> String {
        costEUR.formatted(.currency(code: "EUR").precision(.fractionLength(costEUR < 10 ? 2 : 0)))
    }
}
