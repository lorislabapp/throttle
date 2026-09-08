import Darwin
import Foundation
import ThrottleShared

/// The remote copies and per-transfer Git ref remain available on any conflict.
/// The caller retains the journal's local launch lock throughout installation.
enum RemoteTransferReturn {
    enum Failure: Error, LocalizedError {
        case conflict(String), invalidArtifact
        var errorDescription: String? {
            switch self {
            case .conflict(let detail): "Both copies are preserved. \(detail)"
            case .invalidArtifact: "The returned conversation or repository failed verification."
            }
        }
    }

    static func install(
        record: RemoteTransferRecord, manifest: EdgeTransferService.FrozenManifest,
        transcript: URL, bundle: URL, directory: URL
    ) throws {
        try manifest.validate(id: record.id)
        guard record.phase == .stopped,
              try RemoteTransferJournal.sha256(transcript) == manifest.transcript.sha256,
              try RemoteTransferJournal.sha256(bundle) == manifest.repo.sha256 else { throw Failure.invalidArtifact }
        let runtime: AgentRuntime = record.runtime == "codex" ? .codex : .claudeCode
        let identity = NativeSessionBinding.transcript(runtime: runtime, cwd: record.localCwd, url: transcript)
            ?? NativeSessionBinding.transcript(runtime: runtime, cwd: record.remoteCwd, url: transcript)
        guard identity?.id.caseInsensitiveCompare(record.nativeSessionID) == .orderedSame else {
            throw Failure.invalidArtifact
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try preserveManifest(manifest, directory: directory)
        let cwd = record.localCwd
        try importRepository(manifest: manifest, bundle: bundle, cwd: cwd)
        let localTranscript = URL(fileURLWithPath: record.localTranscriptPath)
        let values = try localTranscript.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalidArtifact }
        let currentHash = try RemoteTransferJournal.sha256(localTranscript)
        guard [record.baselineSHA256, manifest.transcript.sha256].contains(currentHash) else {
            throw Failure.conflict("The local conversation changed after transfer. Compare it with \(transcript.path).")
        }
        let currentTree = try RemoteTransferGit.workingTree(cwd: cwd, directory: directory)
        guard [record.baselineGitTree, manifest.tree].contains(currentTree) else {
            throw Failure.conflict("Local code changed after transfer. The returned work is in \(manifest.ref).")
        }
        if currentTree != manifest.tree {
            let patch = directory.appendingPathComponent("return.patch")
            _ = try RemoteTransferGit.git(["diff", "--binary", "--no-ext-diff", "--no-textconv",
                                           "--output=" + patch.path, record.baselineGitTree, manifest.tree], cwd: cwd)
            _ = try RemoteTransferGit.git(["apply", "--check", "--binary", patch.path], cwd: cwd)
            _ = try RemoteTransferGit.git(["apply", "--binary", patch.path], cwd: cwd)
            guard try RemoteTransferGit.workingTree(cwd: cwd, directory: directory) == manifest.tree else {
                throw Failure.conflict("The returned code needs recovery before local resume.")
            }
        }
        try installConversation(record: record, manifest: manifest, transcript: transcript,
                                currentHash: currentHash, directory: directory)
        guard try RemoteTransferJournal.sha256(localTranscript) == manifest.transcript.sha256,
              try RemoteTransferGit.workingTree(cwd: cwd, directory: directory) == manifest.tree else {
            throw Failure.conflict("The local files changed during return; resume remains suspended.")
        }
    }

    private static func installConversation(
        record: RemoteTransferRecord, manifest: EdgeTransferService.FrozenManifest, transcript: URL,
        currentHash: String, directory: URL
    ) throws {
        let localTranscript = URL(fileURLWithPath: record.localTranscriptPath)
        // Retry after a crash between code and transcript publication is harmless:
        // an already installed tree/hash is accepted, a divergent one is retained.
        if currentHash != manifest.transcript.sha256 {
            let backup = directory.appendingPathComponent("local-baseline.jsonl")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: localTranscript, to: backup)
                try synchronize(backup); try synchronize(directory)
            }
            guard try RemoteTransferJournal.sha256(backup) == record.baselineSHA256,
                  try RemoteTransferJournal.sha256(localTranscript) == record.baselineSHA256 else {
                throw Failure.conflict("The local conversation changed during return.")
            }
            try RemoteTransferTranscript.exchange(source: transcript, destination: localTranscript,
                baselineSHA256: record.baselineSHA256, returnedSHA256: manifest.transcript.sha256, directory: directory)
        }
    }

    private static func preserveManifest(_ manifest: EdgeTransferService.FrozenManifest, directory: URL) throws {
        let manifestFile = directory.appendingPathComponent("return-manifest.json")
        if FileManager.default.fileExists(atPath: manifestFile.path) {
            guard try JSONDecoder().decode(EdgeTransferService.FrozenManifest.self,
                    from: Data(contentsOf: manifestFile)) == manifest
            else { throw Failure.invalidArtifact }
        } else {
            try RemoteTransferFiles.publish(JSONEncoder().encode(manifest), to: manifestFile)
        }
    }

    private static func importRepository(
        manifest: EdgeTransferService.FrozenManifest, bundle: URL, cwd: String
    ) throws {
        let root = try RemoteTransferGit.git(["rev-parse", "--show-toplevel"], cwd: cwd)
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
                == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL
        else { throw Failure.invalidArtifact }
        _ = try RemoteTransferGit.git(["fetch", "--no-tags", bundle.path, "\(manifest.ref):\(manifest.ref)"], cwd: cwd)
        guard try RemoteTransferGit.git(["rev-parse", manifest.ref], cwd: cwd) == manifest.commit,
              try RemoteTransferGit.git(["rev-parse", manifest.ref + "^{tree}"], cwd: cwd) == manifest.tree else {
            throw Failure.invalidArtifact
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw Failure.invalidArtifact }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Failure.invalidArtifact }
    }
}
