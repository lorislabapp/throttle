import Foundation

enum ProjectInstructionProvider: String, Codable, Sendable {
    case codex, claude, copilot, cursor
}

enum ProjectInstructionKind: String, Codable, Sendable {
    case primary, local, rule, skill
}

struct ProjectInstructionSource: Codable, Sendable, Equatable {
    var provider: ProjectInstructionProvider
    var kind: ProjectInstructionKind
    var relativePath: String
    var scopeDirectory: String
    var precedence: Int
    var active: Bool
    var byteCount: Int
    var contentDigest: String
}

/// A content-free inventory of every instruction source that can affect a run.
/// The digest deliberately excludes capturedAt so an unchanged tree reconciles
/// to the same identity.
struct ProjectInstructionSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var targetDirectory: String
    var capturedAt: Date
    var sources: [ProjectInstructionSource]

    var digest: String? {
        guard schemaVersion == 1 else { return nil }
        struct Material: Codable {
            var schemaVersion: Int
            var targetDirectory: String
            var sources: [ProjectInstructionSource]
        }
        return ProjectInstructionService.digest(Material(
            schemaVersion: schemaVersion,
            targetDirectory: targetDirectory,
            sources: sources
        ))
    }
}

enum ProjectInstructionClaimStatus: String, Codable, Sendable {
    case confirmed, hypothesis, unknown
}

struct ProjectInstructionStatement: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var text: String
    var status: ProjectInstructionClaimStatus
    var sourceRefs: [String]
}

struct ProjectInstructionSection: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: String
    var revision: Int
    var title: String
    var statements: [ProjectInstructionStatement]
}

struct ProjectInstructionProposal: Codable, Sendable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID
    var createdAt: Date
    var snapshotDigest: String
    var targetDirectory: String
    var targetRelativePath: String
    var expectedContentDigest: String?
    var proposedContent: String
    var proposedContentDigest: String
    var section: ProjectInstructionSection

    var digest: String? { ProjectInstructionService.digest(self) }
}

enum ProjectInstructionReviewDecision: String, Codable, Sendable {
    case approved, rejected
}

struct ProjectInstructionReview: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var proposalDigest: String
    var decision: ProjectInstructionReviewDecision
    var reviewer: String
    var reviewedAt: Date
}

struct ProjectInstructionApplyReceipt: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var proposalDigest: String
    var snapshotDigest: String
    var targetRelativePath: String
    var previousContentDigest: String?
    var appliedContentDigest: String
    var appliedAt: Date
    var evidenceDirectory: String
    var backupPath: String?
}

enum ProjectInstructionError: Error, Equatable {
    case invalidRoot
    case unsafePath(String)
    case unsafeSource(String)
    case sourceTooLarge(String)
    case invalidSection
    case unconfirmedStatement(String)
    case missingProvenance(String)
    case prohibitedContent(String)
    case staleSnapshot
    case staleTarget
    case reviewRequired
    case evidenceFailure
    case verificationFailed
    case rollbackWouldOverwrite
}
