import Foundation
import GRDB

struct Calibration: Codable, FetchableRecord, PersistableRecord, Sendable {
    var windowKind: String      // matches WindowKind.rawValue
    var capTokens: Int
    var source: String          // "auto" | "anchor_90" | "manual"
    var updatedAt: Int64

    static let databaseTableName = "calibration"

    enum CodingKeys: String, CodingKey {
        case windowKind = "window_kind"
        case capTokens = "cap_tokens"
        case source
        case updatedAt = "updated_at"
    }
}
