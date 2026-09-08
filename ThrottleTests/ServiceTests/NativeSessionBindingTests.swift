import Darwin
import Foundation
@testable import Throttle
import XCTest

final class NativeSessionBindingTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func rollout(
        home: URL, id: String, cwd: String, metadata: [String: Any] = [:]
    ) throws -> URL {
        let directory = home.appendingPathComponent(".codex/sessions/2026/09/07")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-\(id).jsonl")
        var payload = metadata
        payload["id"] = id
        payload["cwd"] = cwd
        let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload])
        try data.write(to: url)
        return url
    }

    func testAmbiguousOwnedSessionsDoNotSelectTheNewest() throws {
        let home = try home()
        let first = try rollout(home: home, id: UUID().uuidString, cwd: "/project")
        let second = try rollout(home: home, id: UUID().uuidString, cwd: "/project")
        let foreign = try rollout(home: home, id: UUID().uuidString, cwd: "/other")
        XCTAssertNil(NativeSessionBinding.uniqueTranscript(
            runtime: .codex, cwd: "/project", writableURLs: [first, second], home: home))
        XCTAssertEqual(NativeSessionBinding.uniqueTranscript(
            runtime: .codex, cwd: "/project", writableURLs: [first, foreign], home: home)?.url, first)
        XCTAssertNil(NativeSessionBinding.uniqueTranscript(
            runtime: .codex, cwd: "/project", writableURLs: [foreign], home: home))
    }

    func testOnlyWritableDescriptorsAreOwnershipEvidence() throws {
        let url = try home().appendingPathComponent("descriptor-test.jsonl")
        try Data("fixture".utf8).write(to: url)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        XCTAssertFalse(NativeSessionBinding.writableFiles(pid: getpid()).contains(url))
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var info = vnode_fdinfowithpath()
        let size = MemoryLayout.size(ofValue: info)
        let copied = proc_pidfdinfo(getpid(), writer.fileDescriptor, PROC_PIDFDVNODEPATHINFO, &info, Int32(size))
        XCTAssertEqual(copied, Int32(size), "Kernel descriptor lookup failed, errno=\(errno)")
        XCTAssertNotEqual(info.pfi.fi_openflags & UInt32(FWRITE), 0)
        let path = withUnsafeBytes(of: info.pvip.vip_path) {
            String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
        }
        XCTAssertEqual(path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL },
                       url.resolvingSymlinksInPath().standardizedFileURL)
        let writable = NativeSessionBinding.writableFiles(pid: getpid())
        XCTAssertTrue(writable.contains(url.resolvingSymlinksInPath().standardizedFileURL),
                      "Writable descriptor scan found \(writable.count) paths")
    }

    func testInProcessSubagentWriterDoesNotHideOrReplaceItsParent() throws {
        let home = try home()
        let parentID = UUID().uuidString
        let parent = try rollout(home: home, id: parentID, cwd: "/project", metadata: ["source": "cli"])
        let child = try rollout(home: home, id: UUID().uuidString, cwd: "/project", metadata: [
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": parentID, "depth": 1]]]
        ])
        let parentWriter = try FileHandle(forWritingTo: parent)
        let childWriter = try FileHandle(forWritingTo: child)
        defer {
            try? parentWriter.close()
            try? childWriter.close()
        }
        let writable = NativeSessionBinding.writableFiles(pid: getpid())
        XCTAssertTrue(writable.contains(parent))
        XCTAssertTrue(writable.contains(child))
        XCTAssertEqual(NativeSessionBinding.uniqueTranscript(
            runtime: .codex, cwd: "/project", writableURLs: writable, home: home)?.id, parentID)
        XCTAssertNil(NativeSessionBinding.uniqueTranscript(
            runtime: .codex, cwd: "/project", writableURLs: [child], home: home))
        XCTAssertNil(NativeSessionBinding.transcript(runtime: .codex, cwd: "/project", url: child))
    }

    func testInternalAndUnknownCodexOriginsCannotBecomeUserSessions() throws {
        let home = try home()
        let rejected: [[String: Any]] = [
            ["source": ["internal": "memory_consolidation"]],
            ["source": ["subagent": "review"]],
            ["source": "unknown"],
            ["source": NSNull()],
            ["source": ["new_origin": "unverified"]],
            ["source": "cli", "thread_source": "subagent"],
            ["source": "cli", "thread_source": "memory_consolidation"]
        ]
        for metadata in rejected {
            let file = try rollout(home: home, id: UUID().uuidString, cwd: "/project", metadata: metadata)
            XCTAssertNil(NativeSessionBinding.transcript(runtime: .codex, cwd: "/project", url: file))
        }
    }

    func testToolAndSubagentDescriptorsCannotBindTheForegroundMission() {
        func process(_ pid: pid_t, parent: pid_t) -> NativeProcessIdentity {
            NativeProcessIdentity(pid: pid, parentPID: parent, userID: geteuid(),
                                  startedSeconds: 1, startedMicroseconds: 0)
        }
        let wrapper = process(10, parent: 2)
        let native = process(11, parent: 10)
        let tool = process(12, parent: 11)
        let subagent = process(13, parent: 12)
        let processes = [wrapper, native, tool, subagent]
        let names: [pid_t: String] = [10: "node", 11: "codex", 12: "python", 13: "codex"]
        XCTAssertEqual(NativeSessionBinding.harnessPID(
            runtime: .codex, foreground: wrapper, processes: processes, names: names), native.pid)
        XCTAssertEqual(NativeSessionBinding.harnessPID(
            runtime: .codex, foreground: native, processes: processes, names: names), native.pid)
        XCTAssertNil(NativeSessionBinding.harnessPID(
            runtime: .codex, foreground: tool, processes: processes, names: names))
        XCTAssertNil(NativeSessionBinding.harnessPID(
            runtime: .claudeCode, foreground: wrapper, processes: processes, names: names))
    }

    @MainActor
    func testBoundTabsNeverAdoptAnotherConversationInTheSameFolder() {
        let aID = UUID().uuidString
        let bID = UUID().uuidString
        let first = CockpitTab(projectName: "A", cwd: "/project", runtime: .codex, resumeSessionId: aID)
        let second = CockpitTab(projectName: "B", cwd: "/project", runtime: .codex, resumeSessionId: bID)
        let external = NativeSessionBinding.Transcript(
            id: UUID().uuidString, url: URL(fileURLWithPath: "/tmp/external.jsonl"), modifiedAt: .now)
        for tab in [first, second] {
            XCTAssertFalse(tab.bindOwnedTranscript(external))
        }
        XCTAssertEqual(first.sessionId, aID)
        XCTAssertEqual(second.sessionId, bID)
    }

    @MainActor
    func testFreshClaudeTabsGetDistinctLaunchIdentities() throws {
        let home = try home()
        let first = CockpitTab(projectName: "A", cwd: "/project")
        let second = CockpitTab(projectName: "B", cwd: "/project", initialPrompt: "continue here")
        let aCommand = try first.agentCommand(
            home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal")))
        let bCommand = try second.agentCommand(
            home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal")))
        XCTAssertTrue(aCommand.contains("claude --session-id"))
        XCTAssertTrue(bCommand.contains("claude --session-id"))
        XCTAssertTrue(bCommand.contains("'continue here'"))
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(
            try first.agentCommand(
                home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal"))),
            aCommand, "Unwritten launch keeps the allocated identity")
    }

    @MainActor
    func testNewCodexTabDoesNotResumeAnExistingCWDConversation() throws {
        let home = try home()
        let existing = UUID().uuidString
        _ = try rollout(home: home, id: existing, cwd: "/project")
        let fresh = CockpitTab(projectName: "New", cwd: "/project", runtime: .codex)
        XCTAssertTrue(
            try fresh.agentCommand(
                home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal"))
            ).hasSuffix("codex"))
        XCTAssertNil(fresh.sessionId)
        let restored = CockpitTab(projectName: "Saved", cwd: "/project", runtime: .codex,
                                  resumeSessionId: existing)
        XCTAssertTrue(
            try restored.agentCommand(
                home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal"))
            ).contains("codex resume '\(existing)'"))
        XCTAssertEqual(restored.sessionId, existing)
    }

    @MainActor
    func testMissingSavedIdentityPersistsUntilAnActualPickerChoice() throws {
        let home = try home()
        let missing = UUID().uuidString
        let tab = CockpitTab(projectName: "Saved", cwd: "/project", runtime: .codex, resumeSessionId: missing)
        XCTAssertTrue(
            try tab.agentCommand(
                home: home, journal: RemoteTransferJournal(root: home.appendingPathComponent("journal"))
            ).hasSuffix("codex resume"))
        XCTAssertEqual(tab.sessionId, missing)
        XCTAssertTrue(tab.isChoosingNativeSession)
        let chosen = NativeSessionBinding.Transcript(
            id: UUID().uuidString, url: URL(fileURLWithPath: "/tmp/chosen.jsonl"), modifiedAt: .now)
        XCTAssertTrue(tab.bindOwnedTranscript(chosen))
        XCTAssertEqual(tab.sessionId, chosen.id)
        XCTAssertFalse(tab.isChoosingNativeSession)
        XCTAssertNil(tab.resumeIssue)
    }
}
