import CryptoKit
import Darwin
import Foundation

enum ProjectInstructionService {
    static let maximumInstructionBytes = 256 * 1_024
    static let beginPrefix = "<!-- BEGIN THROTTLE PROJECT INSTRUCTIONS: "
    static let endPrefix = "<!-- END THROTTLE PROJECT INSTRUCTIONS: "

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func digest<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return digest(data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func propose(
        projectRoot: URL, snapshot: ProjectInstructionSnapshot,
        targetRelativePath: String, section: ProjectInstructionSection, now: Date = Date()
    ) throws -> ProjectInstructionProposal? {
        guard let snapshotDigest = snapshot.digest else { throw ProjectInstructionError.staleSnapshot }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let targetDirectory = try resolvedRelative(snapshot.targetDirectory, root: root, directory: true)
        let current = try capture(projectRoot: root, targetDirectory: targetDirectory, now: now)
        guard current.digest == snapshotDigest else { throw ProjectInstructionError.staleSnapshot }
        try validate(section)
        let target = try instructionTarget(targetRelativePath, root: root)
        let existing = try currentData(target, root: root)
        let existingText = existing.flatMap { String(bytes: $0, encoding: .utf8) }
        guard existing == nil || existingText != nil else {
            throw ProjectInstructionError.unsafeSource(target.path)
        }
        let proposed = try replacingManagedSection(in: existingText ?? "", with: section)
        let proposedData = Data(proposed.utf8)
        if existing == proposedData { return nil }
        return ProjectInstructionProposal(
            id: UUID(), createdAt: now, snapshotDigest: snapshotDigest,
            targetDirectory: snapshot.targetDirectory, targetRelativePath: targetRelativePath,
            expectedContentDigest: existing.map(digest), proposedContent: proposed,
            proposedContentDigest: digest(proposedData), section: section
        )
    }

    static func replacingManagedSection(in original: String, with section: ProjectInstructionSection) throws -> String {
        let begin = beginPrefix + section.id + " -->"
        let end = endPrefix + section.id + " -->"
        guard !section.id.isEmpty, !original.contains(beginPrefix + section.id + " -->\n" + begin),
              original.components(separatedBy: begin).count <= 2,
              original.components(separatedBy: end).count <= 2 else {
            throw ProjectInstructionError.invalidSection
        }
        let rendered = render(section, begin: begin, end: end)
        if let lower = original.range(of: begin), let upper = original.range(of: end),
           lower.lowerBound < upper.lowerBound {
            var result = original
            result.replaceSubrange(lower.lowerBound..<upper.upperBound, with: rendered)
            return result
        }
        guard !original.contains(begin) && !original.contains(end) else {
            throw ProjectInstructionError.invalidSection
        }
        let separator = original.isEmpty ? "" : (original.hasSuffix("\n") ? "\n" : "\n\n")
        return original + separator + rendered + "\n"
    }

    private static func render(_ section: ProjectInstructionSection, begin: String, end: String) -> String {
        let statements = section.statements.map { "- " + $0.text }.joined(separator: "\n")
        return """
        \(begin)
        <!-- throttle-schema: \(section.schemaVersion); revision: \(section.revision) -->
        ## \(section.title)

        \(statements)
        \(end)
        """
    }

    private static func validate(_ section: ProjectInstructionSection) throws {
        let allowedID = section.id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
                                         options: .regularExpression) != nil
        guard section.schemaVersion == 1, section.revision > 0, allowedID,
              !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !section.statements.isEmpty, Set(section.statements.map(\.id)).count == section.statements.count else {
            throw ProjectInstructionError.invalidSection
        }
        for statement in section.statements {
            guard statement.status == .confirmed else {
                throw ProjectInstructionError.unconfirmedStatement(statement.id)
            }
            let hasProvenance = statement.sourceRefs.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !statement.sourceRefs.isEmpty, hasProvenance else {
                throw ProjectInstructionError.missingProvenance(statement.id)
            }
            let text = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !containsProhibitedContent(text) else {
                throw ProjectInstructionError.prohibitedContent(statement.id)
            }
        }
    }

    private static func containsProhibitedContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains(".throttle/log/") || lower.contains(".throttle/state/")
            || lower.contains("session.jsonl") || lower.contains(beginPrefix.lowercased()) {
            return true
        }
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{16,}|"#
                + #"github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b"#,
            #"\bBearer\s+[A-Za-z0-9._~-]{20,}"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func instructionTarget(_ relative: String, root: URL) throws -> URL {
        let normalized = pathlib(relative)
        let allowed = normalized == "AGENTS.md" || normalized == "AGENTS.override.md"
            || normalized == "CLAUDE.md" || normalized == ".github/copilot-instructions.md"
            || (normalized.hasPrefix(".claude/rules/") && normalized.hasSuffix(".md"))
            || (normalized.hasPrefix(".cursor/rules/") && normalized.hasSuffix(".mdc"))
        guard allowed else { throw ProjectInstructionError.unsafePath(relative) }
        return try resolvedRelative(normalized, root: root, directory: false)
    }

    static func currentData(_ url: URL, root: URL) throws -> Data? {
        guard isInside(url.standardizedFileURL, root: root) else {
            throw ProjectInstructionError.unsafePath(url.path)
        }
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return nil }
        guard !hasSymlinkComponent(url, root: root) else {
            throw ProjectInstructionError.unsafeSource(url.path)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProjectInstructionError.unsafeSource(url.path)
        }
        guard (values.fileSize ?? maximumInstructionBytes + 1) <= maximumInstructionBytes else {
            throw ProjectInstructionError.sourceTooLarge(url.path)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func resolvedRelative(_ relative: String, root: URL, directory: Bool) throws -> URL {
        let normalized = pathlib(relative)
        guard normalized != "..", !normalized.hasPrefix("../") else {
            throw ProjectInstructionError.unsafePath(relative)
        }
        let url = normalized == "." ? root : root.appendingPathComponent(normalized, isDirectory: directory)
        guard isInside(url.standardizedFileURL, root: root) else {
            throw ProjectInstructionError.unsafePath(relative)
        }
        return url.standardizedFileURL
    }

    private static func pathlib(_ relative: String) -> String {
        NSString(string: relative).standardizingPath
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.count >= base.count && Array(path.prefix(base.count)) == base
    }

    static func hasSymlinkComponent(_ target: URL, root: URL) -> Bool {
        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

}
