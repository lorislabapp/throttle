import Foundation
import GRDB

struct FileState: Codable, FetchableRecord, PersistableRecord, Sendable {
    var path: String
    var lastOffset: Int64
    var lastMtime: Int64
    var encodedProject: String?
    var sessionId: String?

    static let databaseTableName = "file_state"

    enum CodingKeys: String, CodingKey {
        case path
        case lastOffset = "last_offset"
        case lastMtime = "last_mtime"
        case encodedProject = "encoded_project"
        case sessionId = "session_id"
    }

    /// Session UUID = basename of the JSONL minus the extension.
    static func sessionId(from path: String) -> String? {
        let last = (path as NSString).lastPathComponent
        guard last.hasSuffix(".jsonl") else { return nil }
        return String(last.dropLast(".jsonl".count))
    }

    /// Extract the `<encoded>` segment from a path of the form
    /// `~/.claude/projects/<encoded>/<session>.jsonl`. Returns nil for
    /// any path that doesn't fit the layout.
    static func encodedProject(from path: String) -> String? {
        guard let projectsRange = path.range(of: "/projects/") else { return nil }
        let after = path[projectsRange.upperBound...]
        guard let slash = after.firstIndex(of: "/") else { return nil }
        return String(after[..<slash])
    }
}
