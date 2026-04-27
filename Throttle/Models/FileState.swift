import Foundation
import GRDB

struct FileState: Codable, FetchableRecord, PersistableRecord, Sendable {
    var path: String
    var lastOffset: Int64
    var lastMtime: Int64

    static let databaseTableName = "file_state"

    enum CodingKeys: String, CodingKey {
        case path
        case lastOffset = "last_offset"
        case lastMtime = "last_mtime"
    }
}
