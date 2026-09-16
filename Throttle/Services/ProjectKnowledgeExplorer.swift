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
        ".git", ".throttle", ".ssh", ".gnupg", ".aws", ".azure", ".kube"
    ]
    private static let refusedFileNames: Set<String> = [
        ".npmrc", ".pypirc", "credentials", "credentials.json",
        "id_dsa", "id_ecdsa", "id_ed25519", "id_rsa"
    ]
    private static let refusedExtensions: Set<String> = [
        "key", "mobileprovision", "p12", "p8", "pem"
    ]

    let root: URL
    let files = FileManager.default

    init(projectRoot: URL) {
        root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    func list(relativeDirectory: String = "", now: Date = Date()) throws -> ProjectKnowledgeResult {
        let directory = try resolved(relativeDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ProjectKnowledgeError.notDirectory }
        let values = try files.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0) }
        let safe = values.filter { url in
            guard !Self.isSensitivePath(relative(url)) else { return false }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            let type = info.st_mode & S_IFMT
            return type == S_IFDIR || type == S_IFREG
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let visible = Array(safe.prefix(Self.maximumEntries))
        let lines = visible.map { url in
            let suffix = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? "/" : ""
            return relative(url) + suffix
        }
        return ProjectKnowledgeResult(
            text: lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n"),
            receipt: receipt(
                operation: .list,
                accesses: [],
                truncated: safe.count > visible.count,
                limits: ["entries": Self.maximumEntries],
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

    func readFile(
        _ relativePath: String,
        maximumBytes: Int = ProjectKnowledgeExplorer.maximumFileBytes
    ) throws -> ProjectKnowledgeFile {
        guard maximumBytes > 0 else { throw ProjectKnowledgeError.fileTooLarge }
        guard !Self.isSensitivePath(relativePath) else {
            throw ProjectKnowledgeError.sensitivePathRefused
        }
        let url = try resolved(relativePath, allowRoot: false)
        var linkInfo = stat()
        guard lstat(url.path, &linkInfo) == 0 else { throw ProjectKnowledgeError.notRegularFile }
        guard (linkInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw ProjectKnowledgeError.symlinkRefused
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectKnowledgeError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= min(Int64(Self.maximumFileBytes), Int64(maximumBytes)) else {
            throw info.st_size > min(Int64(Self.maximumFileBytes), Int64(maximumBytes))
                ? ProjectKnowledgeError.fileTooLarge
                : ProjectKnowledgeError.notRegularFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(),
              data.count <= maximumBytes,
              !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            throw ProjectKnowledgeError.binaryOrNonUTF8
        }
        return ProjectKnowledgeFile(url: url, data: data, text: text)
    }

    func resolved(_ path: String, allowRoot: Bool) throws -> URL {
        guard !path.hasPrefix("/"),
              path != "..",
              !path.hasPrefix("../"),
              !path.contains("/../"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              allowRoot || !path.isEmpty else {
            throw ProjectKnowledgeError.invalidRequest
        }
        let unresolved = root.appendingPathComponent(path).standardizedFileURL
        guard !hasSymlinkComponent(unresolved) else {
            throw ProjectKnowledgeError.symlinkRefused
        }
        let candidate = unresolved.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(prefix) else {
            throw ProjectKnowledgeError.pathEscapesRoot
        }
        return candidate
    }

    private func hasSymlinkComponent(_ target: URL) -> Bool {
        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0,
               info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
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
