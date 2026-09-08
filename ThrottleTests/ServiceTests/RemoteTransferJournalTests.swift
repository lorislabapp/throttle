@testable import Throttle
import XCTest

@MainActor
final class RemoteTransferJournalTests: XCTestCase {
    private func fixture() throws -> (RemoteTransferJournal, RemoteTransferRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("throttle-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let journal = RemoteTransferJournal(root: root)
        let record = RemoteTransferRecord(
            contractVersion: 2, id: UUID().uuidString.lowercased(), endpoint: "https://fixture.invalid",
            serverID: UUID().uuidString,
            runtime: "codex", nativeSessionID: UUID().uuidString, projectName: "Fixture",
            localCwd: "/source", remoteCwd: "/remote", localTranscriptPath: "/transcript.jsonl",
            baselineSHA256: String(repeating: "a", count: 64), repoSHA256: String(repeating: "b", count: 64),
            baselineGitTree: String(repeating: "c", count: 40), nativeFilename: "fixture.jsonl",
            createdAt: Date(timeIntervalSince1970: 1000),
            phase: .prepared)
        return (journal, record)
    }

    func testPreparedTransferSurvivesRelaunchAndPreventsDuplicateWriter() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        let relaunched = RemoteTransferJournal(root: journal.root)
        XCTAssertEqual(
            try relaunched.outstanding(runtime: "codex", nativeID: record.nativeSessionID.lowercased()),
            record)
        XCTAssertThrowsError(try relaunched.begin(record))
        XCTAssertNil(try relaunched.outstanding(runtime: "claude", nativeID: record.nativeSessionID))
    }

    func testReturnRequiresStopAndVerifiedHashBeforeReleasingLocalWriter() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        var next = record
        next.phase = .returned
        next.returnedSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try journal.update(next))
        next.phase = .stopped
        next.returnedSHA256 = nil
        try journal.update(next)
        next.phase = .returned
        XCTAssertThrowsError(try journal.update(next))
        next.returnedSHA256 = String(repeating: "b", count: 64)
        try journal.update(next)
        XCTAssertNil(try journal.outstanding(runtime: "codex", nativeID: record.nativeSessionID))
        next.phase = .remote
        XCTAssertThrowsError(try journal.update(next))
    }

    func testTruncatedOrMismatchedJournalCannotPermitLocalResume() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        let file = journal.root.appendingPathComponent(record.id + ".json")
        try Data("{truncated".utf8).write(to: file)
        XCTAssertThrowsError(try journal.outstanding(runtime: "codex", nativeID: record.nativeSessionID))
        try JSONEncoder().encode(record).write(to: file)
        try FileManager.default.moveItem(at: file, to: journal.root.appendingPathComponent(UUID().uuidString + ".json"))
        XCTAssertThrowsError(try journal.records())
    }

    func testUpdateCannotRebindIdentityOrEndpoint() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for key in ["endpoint", "nativeSessionID", "localCwd"] {
            var altered = object
            altered[key] = key == "nativeSessionID" ? UUID().uuidString : "/another"
            let candidate = try JSONDecoder().decode(RemoteTransferRecord.self,
                                                    from: JSONSerialization.data(withJSONObject: altered))
            XCTAssertThrowsError(try journal.update(candidate))
        }
        object["id"] = "../../escape"
        let traversal = try JSONDecoder().decode(RemoteTransferRecord.self,
                                                from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try journal.begin(traversal))
    }

    func testStreamingHashCoversBytesPastFirstChunk() throws {
        let (journal, _) = try fixture()
        let file = journal.root.appendingPathComponent("large.jsonl")
        var bytes = Data(repeating: 65, count: 1_048_576)
        try bytes.write(to: file)
        let before = try RemoteTransferJournal.sha256(file)
        bytes[bytes.count - 1] = 66
        try bytes.write(to: file)
        XCTAssertNotEqual(try RemoteTransferJournal.sha256(file), before)
    }
    func testPreparationReservationBlocksAliasesAndPickerAcrossSuspension() async throws {
        let (journal, record) = try fixture()
        let token = try XCTUnwrap(RemoteTransferReservation.acquire(runtime: "codex", nativeID: record.nativeSessionID))
        defer { RemoteTransferReservation.release(runtime: "codex", nativeID: record.nativeSessionID, token: token) }
        await Task.yield()
        let alias = CockpitTab(projectName: "Alias", cwd: "/source", runtime: .codex,
                               resumeSessionId: record.nativeSessionID.lowercased())
        XCTAssertTrue(alias.hasRemoteOwnership)
        XCTAssertNil(RemoteTransferReservation.acquire(runtime: "codex", nativeID: record.nativeSessionID))
        RemoteTransferReservation.release(runtime: "codex", nativeID: record.nativeSessionID, token: UUID())
        XCTAssertTrue(alias.hasRemoteOwnership)
        let picker = CockpitTab(projectName: "Picker", cwd: "/source", runtime: .codex,
                                resumeSessionId: UUID().uuidString)
        XCTAssertThrowsError(try picker.agentCommand(home: journal.root, journal: journal))
        XCTAssertFalse(picker.isChoosingNativeSession)
        try journal.begin(record)
        RemoteTransferReservation.release(runtime: "codex", nativeID: record.nativeSessionID, token: token)
        XCTAssertThrowsError(try alias.agentCommand(home: journal.root, journal: journal))
        XCTAssertThrowsError(try picker.agentCommand(home: journal.root, journal: journal))
        var returned = record
        returned.phase = .stopped
        try journal.update(returned)
        returned.phase = .returned
        returned.returnedSHA256 = record.baselineSHA256
        try journal.update(returned)
        XCTAssertTrue(try picker.agentCommand(home: journal.root, journal: journal).hasSuffix("codex resume"))
    }

    func testPickerFailsClosedForUnreadableJournalButKnownOtherIdentityCanResume() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        let otherID = UUID().uuidString.lowercased()
        let nativeRoot = journal.root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: nativeRoot, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": otherID, "cwd": "/source"]]
        try JSONSerialization.data(withJSONObject: metadata)
            .write(to: nativeRoot.appendingPathComponent("rollout-\(otherID).jsonl"))
        let known = CockpitTab(projectName: "Known", cwd: "/source", runtime: .codex, resumeSessionId: otherID)
        XCTAssertTrue(
            try known.agentCommand(home: journal.root, journal: journal).contains("codex resume '\(otherID)'")
        )
        let picker = CockpitTab(projectName: "Picker", cwd: "/source", runtime: .claudeCode,
                                resumeSessionId: UUID().uuidString)
        XCTAssertTrue(try picker.agentCommand(home: journal.root, journal: journal).hasSuffix("claude --resume"))
        try Data("{truncated".utf8).write(to: journal.root.appendingPathComponent(record.id + ".json"))
        XCTAssertThrowsError(try picker.agentCommand(home: journal.root, journal: journal))
    }

    func testReturnReservationStillBlocksAliasesAfterDurableJournalRelease() async throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        let token = try XCTUnwrap(RemoteTransferReservation.acquire(runtime: "codex", nativeID: record.nativeSessionID))
        defer { RemoteTransferReservation.release(runtime: "codex", nativeID: record.nativeSessionID, token: token) }
        var returned = record
        returned.phase = .stopped
        try journal.update(returned)
        returned.phase = .returned
        returned.returnedSHA256 = record.baselineSHA256
        try journal.update(returned)
        await Task.yield()
        let alias = CockpitTab(projectName: "Alias", cwd: "/source", runtime: .codex,
                               resumeSessionId: record.nativeSessionID)
        XCTAssertNil(try journal.outstanding(runtime: "codex", nativeID: record.nativeSessionID))
        XCTAssertTrue(alias.hasRemoteOwnership)
        XCTAssertThrowsError(try alias.agentCommand(home: journal.root, journal: journal))
        RemoteTransferReservation.release(runtime: "codex", nativeID: record.nativeSessionID, token: token)
        alias.allowsNativePicker = { false }
        XCTAssertThrowsError(try alias.agentCommand(home: journal.root, journal: journal))
        alias.allowsNativePicker = { true }
        XCTAssertTrue(try alias.agentCommand(home: journal.root, journal: journal).hasSuffix("codex resume"))
    }

    func testMissingWindowStateRestoresAnUnspawnedTransferEvenWhenLocalDirectoryIsMissing() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        let model = MultiCockpitModel()
        model.restoreTransferTabs(journal: journal)
        let tab = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(tab.sessionId, record.nativeSessionID)
        XCTAssertEqual(tab.offloadedRemoteID, record.id)
        XCTAssertEqual(tab.cwd, record.localCwd)
        XCTAssertTrue(tab.isHibernated)
        XCTAssertFalse(tab.isSpawned)
        XCTAssertNil(tab.shellTerminal)
        XCTAssertEqual(model.transferRecoveryCount, 1)
        model.restoreTransferTabs(journal: journal)
        XCTAssertEqual(model.sessions.count, 1, "Reconciliation must not create duplicate recovery tabs")
    }

    func testOrphanRecoveryReportsUnreadableJournalWithoutHidingExistingTabs() throws {
        let (journal, record) = try fixture()
        try journal.begin(record)
        try Data("{partial".utf8).write(to: journal.root.appendingPathComponent(record.id + ".json"))
        let model = MultiCockpitModel()
        let existing = CockpitTab(projectName: "Unrelated", cwd: "/fixture")
        model.sessions = [existing]
        model.restoreTransferTabs(journal: journal)
        XCTAssertEqual(model.sessions.map(\.id), [existing.id])
        XCTAssertNotNil(model.transferRecoveryIssue)
        XCTAssertFalse(existing.isSpawned)
    }

}
