import Foundation

/// Snapshot through a private index. Only a per-transfer ref is written to the
/// repository; the user's index, branch and working files retain their state.
enum RemoteTransferGit {
    struct Snapshot: Sendable { let bundle: URL; let tree: String; let sha256: String }

    enum Failure: Error, LocalizedError {
        case command(String)
        var errorDescription: String? {
            switch self {
            case .command(let detail): "Repository transfer failed: \(detail)"
            }
        }
    }

    static func snapshot(cwd: String, transferID: String, directory: URL) throws -> Snapshot {
        guard UUID(uuidString: transferID)?.uuidString.lowercased() == transferID else {
            throw Failure.command("Invalid transfer identity")
        }
        let repositoryRoot = try git(["rev-parse", "--show-toplevel"], cwd: cwd)
        guard URL(fileURLWithPath: repositoryRoot).resolvingSymlinksInPath().standardizedFileURL
            == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure.command("Transfer from the repository root so the server resumes in the same project layout")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tree = try workingTree(cwd: cwd, directory: directory)
        let head = try git(["rev-parse", "HEAD"], cwd: cwd)
        let headTree = try git(["rev-parse", "HEAD^{tree}"], cwd: cwd)
        let commit: String
        if tree == headTree {
            commit = head
        } else {
            commit = try git(["commit-tree", tree, "-p", head, "-m", "Throttle transfer snapshot"], cwd: cwd,
                             environment: ["GIT_AUTHOR_NAME": "Throttle", "GIT_AUTHOR_EMAIL": "transfer@localhost",
                    "GIT_COMMITTER_NAME": "Throttle", "GIT_COMMITTER_EMAIL": "transfer@localhost"
                ])
        }
        let ref = "refs/throttle/transfers/\(transferID)/outbound"
        _ = try git(["update-ref", ref, commit, String(repeating: "0", count: head.count)], cwd: cwd)
        let bundle = directory.appendingPathComponent("outbound.bundle")
        _ = try git(["bundle", "create", bundle.path, "HEAD", ref], cwd: cwd, timeout: 180)
        let file = try FileHandle(forWritingTo: bundle)
        try file.synchronize(); try file.close()
        return Snapshot(bundle: bundle, tree: tree, sha256: try RemoteTransferJournal.sha256(bundle))
    }

    static func workingTree(cwd: String, directory: URL) throws -> String {
        let index = directory.appendingPathComponent("index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        _ = try git(["read-tree", "HEAD"], cwd: cwd, environment: environment)
        _ = try git(["add", "-A", "."], cwd: cwd, environment: environment)
        try addDeclaredFiles(cwd: cwd, environment: environment)
        return try git(["write-tree"], cwd: cwd, environment: environment)
    }

    private static func addDeclaredFiles(cwd: String, environment: [String: String]) throws {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(".throttleinclude")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 65_536 else { throw Failure.command("Invalid .throttleinclude") }
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { continue }
            _ = try git(["add", "-f", "--", pattern], cwd: cwd, environment: environment)
        }
    }

    static func git(
        _ arguments: [String], cwd: String,
        environment: [String: String] = [:], timeout: TimeInterval = 30
    ) throws -> String {
        let assignments = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let command = (["/usr/bin/env"] + assignments + ["/usr/bin/git", "-C", cwd] + arguments)
            .map(quote).joined(separator: " ")
        let result = TaskIntegrationService.shell(command, in: URL(fileURLWithPath: cwd), timeout: timeout)
        guard result.ok else { throw Failure.command(String(result.output.suffix(2_000))) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
