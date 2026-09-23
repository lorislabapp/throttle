import Darwin
import Foundation
import Testing
@testable import Throttle

@Suite("Plan MCP authority lifecycle")
struct PlanMCPAuthorityLifecycleTests {
    @Test("closing the owning session durably invalidates its grant")
    func closeRevokesGrant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("authority-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertPermissions.change(root.path, to: 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = root.appendingPathComponent("grant.json")
        let now = Date(timeIntervalSince1970: 1_000)
        let grant = PlanMCPAuthority(
            projectRoots: [root],
            author: "codex:task",
            operations: Set(PlanMCPAuthority.Operation.allCases),
            taskID: "T1",
            missionID: UUID(),
            issuedAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(600)
        )
        try grant.encoded().write(to: descriptor)
        XCTAssertPermissions.change(descriptor.path, to: 0o600)

        let result = PlanMCPAuthorityLifecycle.closeSession(
            launchEnvironment: [PlanMCPAuthority.environmentKey + "=" + descriptor.path],
            actor: "throttle:cockpit",
            now: now
        )
        guard case .revoked(let receipt) = result else {
            Issue.record("expected a durable revocation receipt")
            return
        }
        #expect(receipt.grantID == grant.grantID)
        #expect(PlanMCPAuthority.load(
            environment: [PlanMCPAuthority.environmentKey: descriptor.path],
            now: now
        ) == .failure(.revoked))
    }

    @Test("hibernation callers can omit the close hook and an expired grant is already inactive")
    func absentAndExpiredAreInactive() throws {
        #expect(PlanMCPAuthorityLifecycle.closeSession(
            launchEnvironment: [],
            actor: "throttle:cockpit"
        ) == .inactive)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("authority-expired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertPermissions.change(root.path, to: 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = root.appendingPathComponent("grant.json")
        let now = Date(timeIntervalSince1970: 2_000)
        let grant = PlanMCPAuthority(
            projectRoots: [root],
            author: "codex:task",
            operations: [.read],
            taskID: "T1",
            missionID: UUID(),
            issuedAt: now.addingTimeInterval(-100),
            expiresAt: now.addingTimeInterval(-1)
        )
        try grant.encoded().write(to: descriptor)
        XCTAssertPermissions.change(descriptor.path, to: 0o600)
        #expect(PlanMCPAuthorityLifecycle.closeSession(
            launchEnvironment: [PlanMCPAuthority.environmentKey + "=" + descriptor.path],
            actor: "throttle:cockpit",
            now: now
        ) == .inactive)
    }
}

private enum XCTAssertPermissions {
    static func change(_ path: String, to mode: mode_t) {
        #expect(chmod(path, mode) == 0)
    }
}
