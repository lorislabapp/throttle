import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

final class RemoteTransferReturnTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repo: URL
        let record: RemoteTransferRecord
        let manifest: EdgeTransferService.FrozenManifest
        let transcript: URL
        let bundle: URL
        var directory: URL { root.appendingPathComponent("artifacts") }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("throttle-return-\(UUID())")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String], at directory: URL? = nil) throws -> String {
            try RemoteTransferGit.git(args, cwd: (directory ?? repo).path)
        }
        try prepareLocalRepository(repo)
        let id = UUID().uuidString.lowercased(), native = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent("artifacts")
        let outgoing = try RemoteTransferGit.snapshot(cwd: repo.path, transferID: id, directory: directory)
        let remote = root.appendingPathComponent("remote")
        _ = try git(["clone", "--quiet", outgoing.bundle.path, remote.path])
        let outbound = "refs/throttle/transfers/\(id)/outbound"
        _ = try git(["fetch", "--quiet", outgoing.bundle.path, "\(outbound):\(outbound)"], at: remote)
        _ = try git(["checkout", "--quiet", "--detach", outbound], at: remote)
        try Data("remote work\n".utf8).write(to: remote.appendingPathComponent("work.txt"))
        try Data("new remote file\n".utf8).write(to: remote.appendingPathComponent("new.txt"))
        try FileManager.default.removeItem(at: remote.appendingPathComponent("removed.txt"))
        let tree = try RemoteTransferGit.workingTree(cwd: remote.path, directory: directory)
        let head = try git(["rev-parse", "HEAD"], at: remote)
        let commit = try RemoteTransferGit.git(["commit-tree", tree, "-p", head, "-m", "return"], cwd: remote.path,
            environment: ["GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "test@localhost",
                          "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "test@localhost"])
        let ref = "refs/throttle/transfers/\(id)/return"
        _ = try git(["update-ref", ref, commit], at: remote)
        let bundle = directory.appendingPathComponent("return.bundle")
        _ = try git(["bundle", "create", bundle.path, ref], at: remote)
        let localTranscript = root.appendingPathComponent("rollout-\(native).jsonl")
        var bytes = try JSONSerialization.data(withJSONObject: ["type": "session_meta",
                                                               "payload": ["id": native, "cwd": repo.path]])
        bytes.append(10)
        try bytes.write(to: localTranscript)
        let baselineHash = try RemoteTransferJournal.sha256(localTranscript)
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":{\"message\":\"remote progress\"}}\n".utf8))
        let transcript = directory.appendingPathComponent("returned.jsonl")
        try bytes.write(to: transcript)
        let manifest = try manifest(tree: tree, commit: commit, ref: ref, transcript: transcript, bundle: bundle)
        let record = RemoteTransferRecord(contractVersion: 2, id: id, endpoint: "https://fixture.invalid",
            serverID: UUID().uuidString, runtime: "codex", nativeSessionID: native, projectName: "Fixture",
            localCwd: repo.path, remoteCwd: remote.path, localTranscriptPath: localTranscript.path,
            baselineSHA256: baselineHash, repoSHA256: outgoing.sha256, baselineGitTree: outgoing.tree,
            nativeFilename: localTranscript.lastPathComponent, createdAt: .now, phase: .stopped)
        return Fixture(
            root: root, repo: repo, record: record, manifest: manifest, transcript: transcript, bundle: bundle
        )
    }

    private func manifest(
        tree: String, commit: String, ref: String, transcript: URL, bundle: URL
    ) throws -> EdgeTransferService.FrozenManifest {
        func artifact(_ file: URL) throws -> [String: Any] {
            ["bytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
             "sha256": try RemoteTransferJournal.sha256(file)]
        }
        let object: [String: Any] = ["attempt": "return-\(UUID().uuidString.lowercased())", "tree": tree,
                                    "commit": commit, "ref": ref, "transcript": try artifact(transcript),
                                    "repo": try artifact(bundle)]
        return try JSONDecoder().decode(EdgeTransferService.FrozenManifest.self,
                                                from: JSONSerialization.data(withJSONObject: object))
    }

    private func prepareLocalRepository(_ repo: URL) throws {
        func git(_ args: [String]) throws -> String {
            try RemoteTransferGit.git(args, cwd: repo.path)
        }
        _ = try git(["init", "--quiet"])
        for (key, value) in [("user.name", "Fixture"), ("user.email", "test@localhost"),
            ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false"), ("core.fsmonitor", "false")
        ] {
            _ = try git(["config", key, value])
        }
        let tracked = repo.appendingPathComponent("work.txt")
        try Data("committed\n".utf8).write(to: tracked)
        _ = try git(["add", "-A"])
        _ = try git(["commit", "--quiet", "-m", "fixture"])
        try Data("staged\n".utf8).write(to: tracked)
        _ = try git(["add", "work.txt"])
        try Data("local work\n".utf8).write(to: tracked)
        try Data("to remove remotely\n".utf8).write(to: repo.appendingPathComponent("removed.txt"))
    }

    private func install(_ fixture: Fixture) throws {
        try RemoteTransferReturn.install(record: fixture.record, manifest: fixture.manifest,
            transcript: fixture.transcript, bundle: fixture.bundle, directory: fixture.directory)
    }

    func testReturnRestoresCurrentWorkAndConversationWithoutChangingBranchOrIndexAndRetries() throws {
        let fixture = try fixture()
        let beforeIndex = try Data(contentsOf: fixture.repo.appendingPathComponent(".git/index"))
        let beforeHead = try RemoteTransferGit.git(["rev-parse", "HEAD"], cwd: fixture.repo.path)
        try install(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.repo.appendingPathComponent(".git/index")), beforeIndex)
        XCTAssertEqual(try RemoteTransferGit.git(["rev-parse", "HEAD"], cwd: fixture.repo.path), beforeHead)
        XCTAssertEqual(
            try String(contentsOf: fixture.repo.appendingPathComponent("work.txt"), encoding: .utf8),
            "remote work\n")
        XCTAssertEqual(
            try String(contentsOf: fixture.repo.appendingPathComponent("new.txt"), encoding: .utf8),
            "new remote file\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("removed.txt").path))
        XCTAssertEqual(try RemoteTransferJournal.sha256(URL(fileURLWithPath: fixture.record.localTranscriptPath)),
                       fixture.manifest.transcript.sha256)
        XCTAssertEqual(
            try RemoteTransferJournal.sha256(
                fixture.directory.appendingPathComponent("local-baseline.jsonl")),
                       fixture.record.baselineSHA256)
        try install(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.repo.appendingPathComponent(".git/index")), beforeIndex)
    }

    func testDivergentLocalConversationOrCodeRetainsBothCopiesAndNeverReplacesUserFiles() throws {
        for changeTranscript in [true, false] {
            let fixture = try fixture()
            let changed = changeTranscript ? URL(fileURLWithPath: fixture.record.localTranscriptPath)
                : fixture.repo.appendingPathComponent("work.txt")
            try Data("new local edits\n".utf8).write(to: changed)
            XCTAssertThrowsError(try install(fixture))
            XCTAssertEqual(try String(contentsOf: changed, encoding: .utf8), "new local edits\n")
            XCTAssertEqual(try RemoteTransferJournal.sha256(fixture.transcript), fixture.manifest.transcript.sha256)
            XCTAssertEqual(try RemoteTransferGit.git(["rev-parse", fixture.manifest.ref], cwd: fixture.repo.path),
                           fixture.manifest.commit)
        }
    }

    func testInterruptedReturnWithCodeAlreadyAppliedCompletesTheConversation() throws {
        let fixture = try fixture()
        _ = try RemoteTransferGit.git(["fetch", "--quiet", fixture.bundle.path,
            "\(fixture.manifest.ref):\(fixture.manifest.ref)"], cwd: fixture.repo.path)
        let patch = fixture.directory.appendingPathComponent("interruption.patch")
        _ = try RemoteTransferGit.git(["diff", "--binary", "--output=" + patch.path,
            fixture.record.baselineGitTree, fixture.manifest.tree], cwd: fixture.repo.path)
        _ = try RemoteTransferGit.git(["apply", "--binary", patch.path], cwd: fixture.repo.path)
        try install(fixture)
        XCTAssertEqual(try RemoteTransferJournal.sha256(URL(fileURLWithPath: fixture.record.localTranscriptPath)),
                       fixture.manifest.transcript.sha256)
    }
    func testPublicationPreservesAConcurrentWriterAndRestoresItsLocalInode() throws {
        let fixture = try fixture()
        let local = URL(fileURLWithPath: fixture.record.localTranscriptPath)
        let writer = try FileHandle(forWritingTo: local)
        defer { try? writer.close() }
        let before = try Data(contentsOf: local)
        let addition = Data("concurrent local progress\n".utf8)
        XCTAssertThrowsError(try RemoteTransferTranscript.exchange(source: fixture.transcript, destination: local,
            baselineSHA256: fixture.record.baselineSHA256, returnedSHA256: fixture.manifest.transcript.sha256,
            directory: fixture.directory, beforeSwap: {
                try writer.seekToEnd(); try writer.write(contentsOf: addition); try writer.synchronize()
            }))
        XCTAssertEqual(try Data(contentsOf: local), before + addition)
        try writer.write(contentsOf: Data("still open\n".utf8))
        XCTAssertEqual(try Data(contentsOf: local), before + addition + Data("still open\n".utf8))
        let markers = try FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil
        )
            .filter { $0.lastPathComponent.hasPrefix("displaced-transcript-") }
        XCTAssertEqual(markers.count, 1)
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markers[0])) as? [String: String])
        let displaced = try XCTUnwrap(marker["displaced"])
        XCTAssertEqual(
            try RemoteTransferJournal.sha256(URL(fileURLWithPath: displaced)),
            fixture.manifest.transcript.sha256)
    }

    func testPartialMetadataStagingCannotPoisonRetryOrReplaceExistingManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent(".return-manifest.json.interrupted.pending")
        try Data("{partial".utf8).write(to: partial)
        let target = root.appendingPathComponent("return-manifest.json")
        let complete = Data("{\"complete\":true}".utf8)
        try RemoteTransferFiles.publish(complete, to: target)
        XCTAssertEqual(try Data(contentsOf: target), complete)
        XCTAssertEqual(try String(contentsOf: partial, encoding: .utf8), "{partial")
        XCTAssertThrowsError(try RemoteTransferFiles.publish(Data("replacement".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), complete)
    }

}
