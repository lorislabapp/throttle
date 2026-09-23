import Foundation

extension ProjectInstructionService {
    private struct Candidate {
        var provider: ProjectInstructionProvider
        var kind: ProjectInstructionKind
        var url: URL
        var scope: String
        var precedence: Int
        var active: Bool
    }

    static func capture(
        projectRoot: URL,
        targetDirectory: URL,
        now: Date = Date()
    ) throws -> ProjectInstructionSnapshot {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = targetDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard isDirectory(root), isDirectory(target), isInside(target, root: root) else {
            throw ProjectInstructionError.invalidRoot
        }
        let candidates = try candidates(root: root, target: target)
        let sources = try sources(from: candidates, root: root)
        return ProjectInstructionSnapshot(
            targetDirectory: relativePath(target, root: root),
            capturedAt: now,
            sources: sources
        )
    }

    private static func candidates(root: URL, target: URL) throws -> [Candidate] {
        var result: [Candidate] = []
        for (precedence, directory) in directoryChain(root: root, target: target).enumerated() {
            result += try directoryCandidates(
                directory,
                root: root,
                precedence: precedence
            )
        }
        let copilot = root.appendingPathComponent(".github/copilot-instructions.md")
        if FileManager.default.fileExists(atPath: copilot.path) {
            result.append(Candidate(
                provider: .copilot,
                kind: .primary,
                url: copilot,
                scope: ".",
                precedence: 0,
                active: true
            ))
        }
        for (provider, directory) in skillDirectories {
            result += try skillCandidates(
                in: root.appendingPathComponent(directory),
                root: root,
                provider: provider
            )
        }
        return result
    }

    private static var skillDirectories: [(ProjectInstructionProvider, String)] {
        [
            (.claude, ".claude/skills"),
            (.codex, ".agents/skills"),
            (.codex, ".codex/skills")
        ]
    }

    private static func directoryCandidates(
        _ directory: URL,
        root: URL,
        precedence: Int
    ) throws -> [Candidate] {
        let scope = relativePath(directory, root: root)
        var result = codexCandidates(in: directory, scope: scope, precedence: precedence)
        result += claudeCandidates(in: directory, scope: scope, precedence: precedence)
        result += try ruleCandidates(
            in: directory.appendingPathComponent(".claude/rules"),
            root: root,
            provider: .claude,
            precedence: precedence
        )
        result += try ruleCandidates(
            in: directory.appendingPathComponent(".cursor/rules"),
            root: root,
            provider: .cursor,
            precedence: precedence
        )
        return result
    }

    private static func codexCandidates(
        in directory: URL,
        scope: String,
        precedence: Int
    ) -> [Candidate] {
        let urls = [
            directory.appendingPathComponent("AGENTS.override.md"),
            directory.appendingPathComponent("AGENTS.md")
        ]
        let selected = urls.first { nonemptyFile($0) }
        return urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Candidate(
                provider: .codex,
                kind: .primary,
                url: url,
                scope: scope,
                precedence: precedence,
                active: url == selected
            )
        }
    }

    private static func claudeCandidates(
        in directory: URL,
        scope: String,
        precedence: Int
    ) -> [Candidate] {
        ["CLAUDE.md", "CLAUDE.local.md"].compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Candidate(
                provider: .claude,
                kind: name.hasSuffix("local.md") ? .local : .primary,
                url: url,
                scope: scope,
                precedence: precedence,
                active: true
            )
        }
    }

    private static func sources(
        from candidates: [Candidate],
        root: URL
    ) throws -> [ProjectInstructionSource] {
        try candidates.map { candidate in
            let data = try safeData(candidate.url, root: root)
            return ProjectInstructionSource(
                provider: candidate.provider,
                kind: candidate.kind,
                relativePath: relativePath(candidate.url, root: root),
                scopeDirectory: candidate.scope,
                precedence: candidate.precedence,
                active: candidate.active,
                byteCount: data.count,
                contentDigest: digest(data)
            )
        }.sorted {
            ($0.precedence, $0.relativePath) < ($1.precedence, $1.relativePath)
        }
    }

    private static func safeData(_ url: URL, root: URL) throws -> Data {
        guard let data = try currentData(url, root: root) else {
            throw ProjectInstructionError.unsafeSource(url.path)
        }
        return data
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "." }
        return String(path.dropFirst(base.count + 1))
    }

    private static func directoryChain(root: URL, target: URL) -> [URL] {
        let components = Array(target.pathComponents.dropFirst(root.pathComponents.count))
        var result = [root]
        var current = root
        for component in components {
            current.appendPathComponent(component, isDirectory: true)
            result.append(current)
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func nonemptyFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private static func ruleCandidates(
        in directory: URL,
        root: URL,
        provider: ProjectInstructionProvider,
        precedence: Int
    ) throws -> [Candidate] {
        if FileManager.default.fileExists(atPath: directory.path),
           hasSymlinkComponent(directory, root: root) {
            throw ProjectInstructionError.unsafeSource(directory.path)
        }
        guard isDirectory(directory),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.filter {
            $0.pathExtension == (provider == .cursor ? "mdc" : "md")
        }.map {
            Candidate(
                provider: provider,
                kind: .rule,
                url: $0,
                scope: relativePath(
                    directory.deletingLastPathComponent().deletingLastPathComponent(),
                    root: root
                ),
                precedence: precedence,
                active: true
            )
        }
    }

    private static func skillCandidates(
        in directory: URL,
        root: URL,
        provider: ProjectInstructionProvider
    ) throws -> [Candidate] {
        if FileManager.default.fileExists(atPath: directory.path),
           hasSymlinkComponent(directory, root: root) {
            throw ProjectInstructionError.unsafeSource(directory.path)
        }
        guard isDirectory(directory),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }
        return entries.compactMap { entry in
            let url = entry.appendingPathComponent("SKILL.md")
            guard nonemptyFile(url) else { return nil }
            return Candidate(
                provider: provider,
                kind: .skill,
                url: url,
                scope: ".",
                precedence: 0,
                active: true
            )
        }
    }
}
