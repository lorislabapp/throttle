import CryptoKit
import Darwin
import Foundation
import ThrottleShared

/// Filesystem-first, read-only project exploration. The model chooses how to
/// navigate; this boundary fixes the root, refuses symlinked files, caps work and
/// returns an exact receipt for every file whose bytes were inspected.
final class ProjectKnowledgeExplorer: @unchecked Sendable {
    static let maximumEntries = 256
    static let maximumSearchFiles = 128
    static let maximumFileBytes = 1 * 1_024 * 1_024
    static let maximumSearchBytes = 8 * 1_024 * 1_024
    static let maximumMatches = 80
    static let maximumOutputCharacters = 24_000
    static let allowedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "jsx", "ts", "tsx",
        "py", "rb", "go", "rs", "java", "kt", "kts", "sh", "md", "txt", "json",
        "yaml", "yml", "toml", "html", "css", "sql", "graphql", "proto"
    ]
    static let excludedDirectories: Set<String> = [
        ".git", ".build", "build", "DerivedData", "node_modules", "Pods", "Carthage",
        "dist", "out", "target", "vendor", ".venv", "venv", "__pycache__", ".gradle"
    ]
    private static let refusedDirectoryNames: Set<String> = [
        ".git", ".throttle", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config"
    ]
    private static let refusedFileNames: Set<String> = [
        ".npmrc", ".pypirc", ".netrc", ".claude.json", ".credentials.json", "credentials", "credentials.json",
        "id_dsa", "id_ecdsa", "id_ed25519", "id_rsa"
    ]
    private static let refusedExtensions: Set<String> = [
        "key", "mobileprovision", "p12", "p8", "pem"
    ]

    let root: URL
    let rootDescriptor: Int32
    static let maximumVisitedEntries = 4_096

    init(projectRoot: URL) {
        root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    deinit { if rootDescriptor >= 0 { Darwin.close(rootDescriptor) } }

    func list(relativeDirectory: String = "", now: Date = Date()) throws -> ProjectKnowledgeResult {
        var remaining = Self.maximumVisitedEntries
        let entries = try directoryEntries(relativeDirectory, remaining: &remaining)
        let visible = Array(entries.values.prefix(Self.maximumEntries))
        let lines = visible.map { $0.path + ($0.isDirectory ? "/" : "") }
        return ProjectKnowledgeResult(
            text: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"),
            receipt: receipt(
                operation: .list,
                accesses: [],
                truncated: entries.truncated || entries.values.count > visible.count,
                limits: ["entries": Self.maximumEntries, "visited_entries": Self.maximumVisitedEntries],
                now: now
            )
        )
    }

    func read(
        relativePath: String,
        maximumCharacters: Int = 12_000,
        now: Date = Date()
    ) throws -> ProjectKnowledgeResult {
        guard (1_000...64_000).contains(maximumCharacters) else {
            throw ProjectKnowledgeError.invalidRequest
        }
        let file = try readFile(relativePath)
        let redactions = OutboundPolicy.findings(in: file.text)
        let safeText = OutboundPolicy.scrub(file.text)
        let excerpt = String(safeText.prefix(maximumCharacters))
        let lineCount = max(1, excerpt.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        let access = ProjectKnowledgeAccess(
            path: relative(file.url),
            sha256: Self.sha256(file.data),
            bytesRead: file.data.count,
            firstLine: 1,
            lastLine: lineCount
        )
        return ProjectKnowledgeResult(
            text: excerpt,
            receipt: receipt(
                operation: .read,
                accesses: [access],
                redactions: redactions,
                truncated: excerpt.count < safeText.count,
                limits: [
                    "characters": maximumCharacters,
                    "file_bytes": Self.maximumFileBytes
                ],
                now: now
            )
        )
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
            .filter { $0 != "/" && $0 != "." }
        guard let name = components.last?.lowercased() else { return false }
        if components.dropLast().contains(where: { refusedDirectoryNames.contains($0.lowercased()) }) {
            return true
        }
        if refusedDirectoryNames.contains(name) || refusedFileNames.contains(name) {
            return true
        }
        if name == ".env" || name.hasPrefix(".env.") {
            return true
        }
        return refusedExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    func relative(_ url: URL) -> String {
        if url.path == root.path { return "." }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
