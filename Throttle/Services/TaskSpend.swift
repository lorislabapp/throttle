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
        let costEUR: Double?
        /// A transcript alone is not a measurement: ingestion may still be pending.
        var measured: Bool { !sessionIDs.isEmpty && costEUR != nil }
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
                      database: any DatabaseReader,
                      claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
                          .appending(path: ".claude")) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for taskID in taskIDs {
            let sessions = sessionIDs(forTask: taskID, projectRoot: projectRoot, claudeHome: claudeHome)
            let cost: Double? = try? database.read { database -> Double? in
                guard !sessions.isEmpty else { return nil }
                var total = 0.0
                for session in sessions {
                    let observed = try Bool.fetchOne(database, sql: """
                        SELECT EXISTS(SELECT 1 FROM usage_events WHERE session_id = ?)
                        """, arguments: [session]) ?? false
                    guard observed else { return nil }
                    total += try StatsDataService.cockpitSessionCostEUR(in: database, sessionId: session)
                }
                return total.isFinite && total >= 0 ? total : nil
            }
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
        return Total(costEUR: measured.reduce(0) { $0 + ($1.costEUR ?? 0) },
                     measured: measured.count, unmeasured: entries.count - measured.count)
    }

    static func format(_ costEUR: Double) -> String {
        costEUR.formatted(.currency(code: "EUR").precision(.fractionLength(costEUR < 10 ? 2 : 0)))
    }
}
