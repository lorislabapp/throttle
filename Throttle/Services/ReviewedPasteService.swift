import CryptoKit
import Foundation

/// Review metadata for a risky terminal paste. The original text stays only in
/// memory; the challenge proves the confirmed bytes are the bytes that are sent.
struct ReviewedPasteChallenge: Sendable, Equatable {
    let id: UUID
    let sha256: String
    let preview: String
    let byteCount: Int
    let lineCount: Int
    let expiresAt: Date
}

enum ReviewedPasteError: Error, Equatable {
    case empty
    case tooLarge
    case controlSequence
}

enum ReviewedPasteService {
    /// A reviewed terminal paste may be large enough to carry a real build log.
    /// 64 KiB was a conservative command-paste guard, but it made ordinary Xcode
    /// and CI diagnostics unusable. Keep the hash/review gate and cap at 1 MiB to
    /// prevent accidental multi-megabyte clipboard floods.
    static let maximumBytes = 1024 * 1024
    static let reviewBytes = 4 * 1024
    static let reviewLines = 4
    static let timeToLive: TimeInterval = 30

    nonisolated static func requiresReview(_ text: String) -> Bool {
        text.utf8.count > reviewBytes || lineCount(text) >= reviewLines
    }

    nonisolated static func prepare(
        _ text: String,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> ReviewedPasteChallenge {
        guard !text.isEmpty else { throw ReviewedPasteError.empty }
        guard text.utf8.count <= maximumBytes else { throw ReviewedPasteError.tooLarge }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 0x1b }) else {
            throw ReviewedPasteError.controlSequence
        }
        return ReviewedPasteChallenge(
            id: id,
            sha256: digest(text),
            preview: preview(text),
            byteCount: text.utf8.count,
            lineCount: lineCount(text),
            expiresAt: now.addingTimeInterval(timeToLive)
        )
    }

    nonisolated static func validates(
        _ challenge: ReviewedPasteChallenge,
        text: String,
        now: Date = Date()
    ) -> Bool {
        now <= challenge.expiresAt
            && text.utf8.count == challenge.byteCount
            && digest(text) == challenge.sha256
    }

    nonisolated private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func lineCount(_ text: String) -> Int {
        max(1, text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } })
    }

    nonisolated private static func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard compact.count > 240 else { return compact }
        return String(compact.prefix(239)) + "…"
    }
}
