import Foundation

enum ProjectKnowledgeOperation: String, Codable, Sendable {
    case list
    case search
    case read
}

struct ProjectKnowledgeAccess: Codable, Sendable, Equatable {
    var path: String
    var sha256: String
    var bytesRead: Int
    var firstLine: Int
    var lastLine: Int
}

struct ProjectKnowledgeReceipt: Codable, Sendable, Equatable {
    var schemaVersion = 2
    var id: UUID
    var operation: ProjectKnowledgeOperation
    var projectRoot: String
    var createdAt: Date
    var accesses: [ProjectKnowledgeAccess]
    /// Credential shapes removed before text crossed the MCP boundary. Values
    /// name only the redaction kind and never repeat the matched bytes.
    var redactions: [String]
    var truncated: Bool
    var limits: [String: Int]
}

struct ProjectKnowledgeResult: Sendable, Equatable {
    var text: String
    var receipt: ProjectKnowledgeReceipt

    func rendered() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(receipt))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return text + "\n\nRECEIPT " + encoded
    }
}

enum ProjectKnowledgeError: Error, Equatable {
    case invalidRequest
    case pathEscapesRoot
    case symlinkRefused
    case notDirectory
    case notRegularFile
    case fileTooLarge
    case binaryOrNonUTF8
    case sensitivePathRefused
    case unsafeFile
}

struct ProjectKnowledgeFile: Sendable {
    var url: URL
    var data: Data
    var text: String
}
