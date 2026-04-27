import Foundation
import GRDB

struct AppSetting: Codable, FetchableRecord, PersistableRecord, Sendable {
    var key: String
    var value: String

    static let databaseTableName = "settings"
}
