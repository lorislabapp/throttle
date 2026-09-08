import AppKit
import Darwin
import Foundation
import SwiftTerm
@testable import Throttle
import XCTest

@MainActor
final class CockpitLifecycleTests: XCTestCase {
    private var fixtures: [CockpitTerminalFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            let identity = fixture.identity, previousScope = fixture.scope
            let outcome = await Task.detached {
                let scope = OwnedProcessTermination.capture(roots: [identity]) ?? previousScope
                return OwnedProcessTermination.stop(scope, grace: 0.05)
            }.value
            XCTAssertEqual(outcome, .stopped, "Only this test's captured process scope may be cleaned up")
            if outcome == .stopped { try FileManager.default.removeItem(at: fixture.directory) }
        }
        fixtures.removeAll()
        try await super.tearDown()
    }

    func testHibernateConfirmsBothTerminalTreesBeforeReleasingViewsAndKeepsNativeIdentity() async throws {
        let primary = try await fixture(ignoresTerm: true), side = try await fixture()
        let unrelated = try await fixture()
        let tab = tab(primary, side: side)
        let identity = tab.sessionId
        tab.pauseReason = .user
        let stopped = await tab.hibernate()
        XCTAssertTrue(stopped, tab.stopIssue ?? "Both owned terminal groups must have exited")
        XCTAssertTrue(tab.isHibernated)
        XCTAssertFalse(tab.isStopping)
        XCTAssertNil(tab.stopIssue)
        XCTAssertNil(tab.terminal)
        XCTAssertNil(tab.shellTerminal)
        XCTAssertNil(tab.rootProcessIdentity)
        XCTAssertNil(tab.sideShellIdentity)
        XCTAssertNil(tab.pauseReason)
        XCTAssertEqual(tab.sessionId, identity)
        assertGone(primary)
        assertGone(side)
        assertAlive(unrelated)
    }

    func testUnknownOwnerKeepsTerminalVisibleAndBlocksHandoffCloseAndWake() async throws {
        let primary = try await fixture()
        let tab = tab(primary)
        tab.rootProcessIdentity = nil
        let model = model(with: [tab])
        let nativeID = tab.sessionId
        let replacement = await model.continueMission(tab.id, with: handoff(tab))
        XCTAssertNil(replacement)
        XCTAssertEqual(model.sessions.map(\.id), [tab.id])
        XCTAssertNotNil(tab.stopIssue)
        XCTAssertTrue(tab.terminal === primary.terminal)
        XCTAssertTrue(primary.terminal.inputSuspended)
        XCTAssertFalse(tab.isHibernated)
        XCTAssertFalse(tab.isStopping)
        await model.close(tab.id)
        model.wake(tab.id)
        XCTAssertEqual(model.sessions.map(\.id), [tab.id])
        XCTAssertEqual(tab.sessionId, nativeID)
        XCTAssertTrue(tab.terminal === primary.terminal)
        assertAlive(primary)
    }

    func testStaleProcessIdentityCannotConfirmStopOrCreateHandoffTarget() async throws {
        let primary = try await fixture()
        let tab = tab(primary)
        let actual = primary.identity
        tab.rootProcessIdentity = NativeProcessIdentity(pid: actual.pid, parentPID: actual.parentPID,
            userID: actual.userID, startedSeconds: actual.startedSeconds + 1,
            startedMicroseconds: actual.startedMicroseconds)
        let model = model(with: [tab])
        let replacement = await model.continueMission(tab.id, with: handoff(tab))
        XCTAssertNil(replacement)
        XCTAssertEqual(model.sessions.map(\.id), [tab.id])
        XCTAssertNotNil(tab.stopIssue)
        XCTAssertFalse(tab.isStopping)
        XCTAssertTrue(tab.terminal === primary.terminal)
        XCTAssertTrue(primary.terminal.inputSuspended)
        assertAlive(primary)
    }

    func testModelStopFailureKeepsAllTabsAndCancelsQuittingState() async throws {
        let primary = try await fixture(), side = try await fixture()
        let failing = tab(primary, side: side)
        failing.sideShellIdentity = nil
        let untouched = tab(try await fixture())
        let model = model(with: [failing, untouched])
        let stopped = await model.stop()
        XCTAssertFalse(stopped)
        XCTAssertFalse(model.isQuitting)
        XCTAssertEqual(model.sessions.map(\.id), [failing.id, untouched.id])
        XCTAssertNotNil(failing.stopIssue)
        XCTAssertTrue(failing.terminal === primary.terminal)
        XCTAssertTrue(failing.shellTerminal === side.terminal)
        XCTAssertTrue(side.terminal.inputSuspended)
        XCTAssertTrue(untouched.isSpawned)
        assertAlive(primary)
        assertAlive(side)
    }

    func testModelStopClearsSessionsOnlyAfterEveryCapturedTreeHasExited() async throws {
        let primary = try await fixture(), side = try await fixture()
        let first = tab(primary, side: side)
        let secondFixture = try await fixture(), second = tab(secondFixture)
        let model = model(with: [first, second])
        let stopped = await model.stop()
        XCTAssertTrue(stopped)
        XCTAssertTrue(model.isQuitting)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(first.isHibernated)
        XCTAssertTrue(second.isHibernated)
        XCTAssertNil(first.shellTerminal)
        assertGone(primary)
        assertGone(side)
        assertGone(secondFixture)
    }

    func testHandoffCreatesTargetOnlyAfterSourceStopAndPreservesMission() async throws {
        let primary = try await fixture(ignoresTerm: true)
        let source = tab(primary)
        let model = model(with: [source])
        let packet = handoff(source)
        let transition = Task { await model.continueMission(source.id, with: packet) }
        try await eventually { source.isStopping }
        XCTAssertEqual(model.sessions.map(\.id), [source.id])
        XCTAssertTrue(source.terminal === primary.terminal)
        await model.close(source.id)
        model.wake(source.id)
        XCTAssertEqual(model.sessions.map(\.id), [source.id])
        let result = await transition.value
        let target = try XCTUnwrap(result)
        XCTAssertTrue(source.isHibernated)
        XCTAssertEqual(model.sessions.map(\.id), [source.id, target.id])
        XCTAssertEqual(target.missionID, source.missionID)
        XCTAssertEqual(target.runtime, .codex)
        XCTAssertEqual(target.initialPrompt, packet.prompt)
        XCTAssertFalse(target.isSpawned, "The test's launch policy forbids all provider processes")
        assertGone(primary)
    }

    private func model(with tabs: [CockpitTab]) -> MultiCockpitModel {
        let model = MultiCockpitModel()
        // Keep real creation/transition logic, but never launch a provider even
        // if a regression reaches newSession unexpectedly. No saved set is loaded.
        model.sessionLaunchPolicy = { false }
        model.sessions = tabs
        for tab in tabs { model.wire(tab) }
        model.activeID = tabs.first?.id
        XCTAssertFalse(model.sessionsLoaded)
        return model
    }

    private func tab(_ primary: CockpitTerminalFixture, side: CockpitTerminalFixture? = nil) -> CockpitTab {
        let tab = CockpitTab(projectName: "Lifecycle fixture", cwd: primary.directory.path,
                             runtime: .claudeCode, resumeSessionId: UUID().uuidString.lowercased())
        tab.terminal = primary.terminal
        tab.rootProcessIdentity = primary.identity
        tab.shellTerminal = side?.terminal
        tab.sideShellIdentity = side?.identity
        return tab
    }

    private func handoff(_ source: CockpitTab) -> MissionHandoff {
        .init(sourceTabID: source.id, missionID: source.missionID, projectName: source.projectName,
              cwd: source.cwd, source: source.runtime, target: .codex, sourceSessionID: source.sessionId,
              objective: "Continue the isolated lifecycle fixture", git: .unavailable)
    }

    private func fixture(ignoresTerm: Bool = false) async throws -> CockpitTerminalFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let terminal = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let childReady = directory.appendingPathComponent("child-ready")
        // exec keeps the child's PID stable after readiness and never creates
        // an uncaptured sleep grandchild. Ignoring HUP as well as TERM prevents
        // PTY hangup from accidentally bypassing the KILL escalation scenario.
        let child = (ignoresTerm ? "trap '' TERM HUP; " : "")
            + "printf ready > " + MissionRuntimeService.shellQuote(childReady.path)
            + "; exec /bin/sleep 30"
        let command = "trap 'exit 0' TERM; /bin/sh -c " + MissionRuntimeService.shellQuote(child) + " & wait"
        terminal.startProcess(executable: "/bin/sh", args: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "LC_ALL=C"])
        guard let pid = terminal.process?.shellPid, let identity = NativeProcessIdentity.capture(pid) else {
            terminal.terminate()
            throw CocoaError(.executableNotLoadable, userInfo: [NSFilePathErrorKey: directory.path])
        }
        // Register the root immediately, so even a failed readiness assertion
        // leaves an owned scope for asynchronous teardown while SwiftTerm reaps.
        // The child also exits on its own after 30 seconds if the runner dies.
        let initialScope = OwnedProcessTermination.Scope(members: [
            .init(identity: identity, group: getpgid(pid))
        ])
        let fixture = CockpitTerminalFixture(directory: directory, terminal: terminal,
                                             identity: identity, scope: initialScope)
        fixtures.append(fixture)
        try await eventually { FileManager.default.fileExists(atPath: childReady.path) }
        fixture.scope = try XCTUnwrap(OwnedProcessTermination.capture(roots: [identity]))
        XCTAssertEqual(fixture.scope.members.count, 2, "The fixture must contain only the shell and its stable child")
        return fixture
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "The isolated process did not reach its lifecycle checkpoint")
    }

    private func assertAlive(_ fixture: CockpitTerminalFixture) {
        let current = NativeProcessIdentity.capture(fixture.identity.pid)
        XCTAssertTrue(current.map { OwnedProcessTermination.sameProcess($0, fixture.identity) } == true)
    }

    private func assertGone(_ fixture: CockpitTerminalFixture) {
        for member in fixture.scope.members {
            let current = NativeProcessIdentity.capture(member.identity.pid)
            XCTAssertFalse(current.map { OwnedProcessTermination.sameProcess($0, member.identity) } == true)
        }
        for group in fixture.scope.groups {
            let result = kill(-group, 0), error = errno
            // Assertion/reporting code may change errno; retain the syscall's
            // actual result before calling into XCTest.
            XCTAssertEqual(result, -1, "Captured process group \(group) still exists")
            XCTAssertEqual(error, ESRCH, "Captured process group \(group) exit is unconfirmed")
        }
    }
}

@MainActor
private final class CockpitTerminalFixture {
    let directory: URL
    let terminal: DroppableTerminalView
    let identity: NativeProcessIdentity
    var scope: OwnedProcessTermination.Scope

    init(directory: URL, terminal: DroppableTerminalView,
         identity: NativeProcessIdentity, scope: OwnedProcessTermination.Scope) {
        self.directory = directory
        self.terminal = terminal
        self.identity = identity
        self.scope = scope
    }
}
