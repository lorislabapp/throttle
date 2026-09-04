import Foundation
import ResearchVaultModel

public struct ResearchDocumentChunk: Equatable, Sendable {
    public let ordinal: Int
    public let heading: String?
    public let content: String
    public let approximateTokenCount: Int

    public init(ordinal: Int, heading: String?, content: String, approximateTokenCount: Int) {
        self.ordinal = ordinal
        self.heading = heading
        self.content = content
        self.approximateTokenCount = approximateTokenCount
    }
}

public struct ResearchDocumentSearchHit: Equatable, Sendable {
    public let documentID: String
    public let projectKey: String
    public let sensitivity: ResearchSensitivity
    public let title: String
    public let heading: String?
    public let content: String
    public let ordinal: Int
    public let score: Double
    public let plaintextSHA256: String
    public let libraryPath: String
    public let origins: [String]
    public let observedAt: Date
    public let sourceModifiedAt: Date
    public let evidenceStatus: ResearchEvidenceStatus?
    public let indexGeneration: String

    public init(
        documentID: String,
        projectKey: String,
        sensitivity: ResearchSensitivity,
        title: String,
        heading: String?,
        content: String,
        ordinal: Int,
        score: Double,
        plaintextSHA256: String,
        libraryPath: String,
        origins: [String],
        observedAt: Date,
        sourceModifiedAt: Date,
        evidenceStatus: ResearchEvidenceStatus?,
        indexGeneration: String
    ) {
        self.documentID = documentID
        self.projectKey = projectKey
        self.sensitivity = sensitivity
        self.title = title
        self.heading = heading
        self.content = content
        self.ordinal = ordinal
        self.score = score
        self.plaintextSHA256 = plaintextSHA256
        self.libraryPath = libraryPath
        self.origins = origins
        self.observedAt = observedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.evidenceStatus = evidenceStatus
        self.indexGeneration = indexGeneration
    }
}

public enum ResearchDocumentImportResult: Equatable, Sendable {
    case inserted(chunkCount: Int)
    case alreadyPresent
}

public enum ResearchDocumentChunkerError: Error, Equatable, Sendable {
    case targetTooSmall
    case invalidOverlap
}

/// Deterministic Markdown-aware chunker. Headings are metadata, paragraphs are
/// kept intact when possible, and very large paragraphs are split at word
/// boundaries. A bounded tail overlap preserves local context.
public struct ResearchDocumentChunker: Sendable {
    public static let standard = ResearchDocumentChunker(
        validatedTargetCharacters: 1_600,
        overlapCharacters: 240
    )

    public let targetCharacters: Int
    public let overlapCharacters: Int

    public init(targetCharacters: Int = 1_600, overlapCharacters: Int = 240) throws {
        guard targetCharacters >= 256 else {
            throw ResearchDocumentChunkerError.targetTooSmall
        }
        guard overlapCharacters >= 0, overlapCharacters < targetCharacters / 2 else {
            throw ResearchDocumentChunkerError.invalidOverlap
        }
        self.targetCharacters = targetCharacters
        self.overlapCharacters = overlapCharacters
    }

    private init(validatedTargetCharacters: Int, overlapCharacters: Int) {
        self.targetCharacters = validatedTargetCharacters
        self.overlapCharacters = overlapCharacters
    }

    public func chunks(for markdown: String) -> [ResearchDocumentChunk] {
        var heading: String?
        var blocks: [(String?, String)] = []
        var paragraph: [Substring] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append((heading, paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), let firstText = trimmed.firstIndex(where: { $0 != "#" && !$0.isWhitespace }) {
                flushParagraph()
                heading = String(trimmed[firstText...]).trimmingCharacters(in: .whitespaces)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()

        var raw: [(String?, String)] = []
        var currentHeading: String?
        var current = ""
        for (blockHeading, block) in blocks {
            for piece in splitOversized(block) {
                if current.isEmpty {
                    currentHeading = blockHeading
                    current = piece
                } else if current.count + 2 + piece.count <= targetCharacters {
                    current += "\n\n" + piece
                } else {
                    raw.append((currentHeading, current))
                    let overlap = tail(current, maximum: overlapCharacters)
                    currentHeading = blockHeading
                    current = overlap.isEmpty ? piece : overlap + "\n\n" + piece
                }
            }
        }
        if !current.isEmpty { raw.append((currentHeading, current)) }

        return raw.enumerated().map { index, item in
            ResearchDocumentChunk(
                ordinal: index,
                heading: item.0,
                content: item.1,
                approximateTokenCount: max(1, Int(ceil(Double(item.1.utf8.count) / 4.0)))
            )
        }
    }

    private func splitOversized(_ text: String) -> [String] {
        guard text.count > targetCharacters else { return [text] }
        var output: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(word)
            if !current.isEmpty, current.count + 1 + word.count > targetCharacters {
                output.append(current)
                current = word
            } else {
                current += (current.isEmpty ? "" : " ") + word
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    private func tail(_ text: String, maximum: Int) -> String {
        guard maximum > 0, text.count > maximum else { return maximum == 0 ? "" : text }
        let start = text.index(text.endIndex, offsetBy: -maximum)
        let suffix = text[start...]
        if let boundary = suffix.firstIndex(where: { $0.isWhitespace }) {
            return String(suffix[suffix.index(after: boundary)...])
        }
        return String(suffix)
    }
}
