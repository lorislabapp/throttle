@testable import Throttle
import XCTest

/// MCP calls require a valid grant; trusted controller services remain explicit.
final class PlanMCPAuthorityTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")
    private let grantID = UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID()
    private let missionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var project: URL { root.appendingPathComponent("project", isDirectory: true) }

    private func grant(operations: Set<PlanMCPAuthority.Operation> = [.read, .claim, .event],
                       expiresAt: Date? = nil) -> PlanMCPAuthority {
        PlanMCPAuthority(
            projectRoots: [project],
            author: "codex:t1",
            operations: operations,
            taskID: "T1",
            missionID: missionID,
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: expiresAt ?? Date(timeIntervalSince1970: 2_100_000_000),
            grantID: grantID
        )
    }

    private func write(_ authority: PlanMCPAuthority, permissions: Int = 0o600) throws -> String {
        let url = root.appendingPathComponent("authority.json")
        try authority.encoded().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        return url.path
    }

    func test_noDescriptorIsALegacyCaller() {
        XCTAssertEqual(PlanMCPAuthority.load(environment: [:]), .success(nil))
        XCTAssertEqual(PlanMCPAuthority.load(environment: [PlanMCPAuthority.environmentKey: ""]), .success(nil))
    }

    func testAbsentGrantRefusesEveryTaskToolWithoutCreatingAPlan() {
        for name in ["throttle_plan_read", "throttle_task_claim", "throttle_task_event", "throttle_task_verdict"] {
            var response = ""
            PlanMCPTools.routeTaskCall(name, ["project": project.path, "task_id": "T1", "by": "codex:t1"],
                                      authority: .success(nil), { response = $0 }, { _ in response = "rpc error" })
            XCTAssertTrue(response.contains("explicit runtime authority"), response)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".throttle").path))
    }

    func testRevocationAfterPreflightPreventsClaimAtMutationBoundary() throws {
        let store = PlanStore(projectRoot: project)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "T1", title: "Task")]))
        let path = try write(grant())
        let environment = [PlanMCPAuthority.environmentKey: path]
        let args: [String: Any] = ["project": project.path, "task_id": "T1", "by": "codex:t1"]
        XCTAssertNil(PlanMCPTools.authorityRefusal(
            "throttle_task_claim", args, PlanMCPAuthority.load(environment: environment)))
        try PlanMCPAuthority.revoke(descriptorURL: URL(fileURLWithPath: path), by: "test", reason: "fixture")
        let response = PlanMCPTools.claimText(project: project.path, taskID: "T1", author: "codex:t1", missionID: nil,
            authorizeMutation: {
                PlanMCPTools.authorityRefusal(
                    "throttle_task_claim", args, PlanMCPAuthority.load(environment: environment))
            })
        XCTAssertTrue(response.contains("revoked"), response)
        XCTAssertTrue(try store.events(for: "T1").events.isEmpty)
    }

    func testMutationBoundaryRefusesEventAndVerdictBeforePersistence() throws {
        let store = PlanStore(projectRoot: project)
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [PlanTask(id: "T1", title: "Task")]))
        let denied = "Refused: expired at mutation boundary"
        var event = PlanMCPTools.EventRequest(project: project.path, taskID: "T1", author: "codex:t1", type: "progress")
        event.authorizeMutation = { denied }
        var verdict = PlanMCPTools.VerdictRequest(
            project: project.path, taskID: "T1", author: "judge:t2", verdict: "verified")
        verdict.authorizeMutation = { denied }
        XCTAssertEqual(PlanMCPTools.eventText(event), denied)
        XCTAssertEqual(PlanMCPTools.verdictText(verdict), denied)
        XCTAssertTrue(try store.events(for: "T1").events.isEmpty)
    }

    func test_aPrivateDescriptorLoadsAndNarrowsCalls() throws {
        let path = try write(grant())
        let environment = [PlanMCPAuthority.environmentKey: path]
        let loaded = try XCTUnwrap(try PlanMCPAuthority.load(environment: environment).get())
        XCTAssertEqual(loaded, grant())
        XCTAssertNil(loaded.refusal(project: project.path, author: "codex:t1", operation: .claim,
                                    requestedTaskID: "T1"))
        XCTAssertNil(loaded.refusal(project: project.path + "/", author: "codex:t1", operation: .read,
                                    requestedTaskID: nil),
                     "a trailing slash is the same project")
        XCTAssertNotNil(loaded.refusal(project: root.path, author: "codex:t1", operation: .claim,
                                       requestedTaskID: "T1"),
                        "a sibling directory is another project")
        XCTAssertNotNil(loaded.refusal(project: project.path, author: "codex:t2", operation: .claim,
                                       requestedTaskID: "T1"))
        XCTAssertNotNil(loaded.refusal(project: project.path, author: "codex:t1", operation: .verdict,
                                       requestedTaskID: "T1"),
                        "verdict was not granted")
    }

    func test_symlinkedProjectResolvesToTheGrantedRoot() throws {
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        XCTAssertNil(grant().refusal(project: link.path, author: "codex:t1", operation: .read,
                                     requestedTaskID: nil))
    }

    func testGrantIsBoundToOneTaskAndRechecksItsDeadline() {
        let authority = grant()
        XCTAssertNotNil(authority.refusal(
            project: project.path,
            author: "codex:t1",
            operation: .event,
            requestedTaskID: "T2"
        ))
        XCTAssertEqual(authority.refusal(
            project: project.path,
            author: "codex:t1",
            operation: .event,
            requestedTaskID: "T1",
            now: Date(timeIntervalSince1970: 2_100_000_001)
        ), PlanMCPAuthority.refusal(for: .expired))
    }

    func testRevocationPersistsAPrivateReceiptAndStopsFutureCalls() throws {
        let descriptor = URL(fileURLWithPath: try write(grant()))
        let receipt = try PlanMCPAuthority.revoke(
            descriptorURL: descriptor,
            by: "throttle:test",
            reason: "task released",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(receipt.grantID, grantID)
        XCTAssertEqual(receipt.taskID, "T1")
        XCTAssertEqual(
            PlanMCPAuthority.load(
                environment: [PlanMCPAuthority.environmentKey: descriptor.path],
                now: Date(timeIntervalSince1970: 1_800_000_001)
            ),
            .failure(.revoked)
        )
        let marker = descriptor.deletingLastPathComponent()
            .appendingPathComponent("revocations/\(grantID.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        XCTAssertEqual(
            try PlanMCPAuthority.revoke(
                descriptorURL: descriptor,
                by: "ignored",
                reason: "cannot rewrite the first receipt",
                now: Date(timeIntervalSince1970: 1_800_000_002)
            ),
            receipt
        )
    }

    func test_unsafeMalformedOrExpiredDescriptorsRefuseEverything() throws {
        let shared = try write(grant(), permissions: 0o644)
        XCTAssertEqual(PlanMCPAuthority.load(environment: [PlanMCPAuthority.environmentKey: shared]),
                       .failure(.unsafe(shared)))
        let expired = try write(grant(expiresAt: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(PlanMCPAuthority.load(environment: [PlanMCPAuthority.environmentKey: expired],
                                             now: Date(timeIntervalSince1970: 11)), .failure(.expired))
        XCTAssertEqual(PlanMCPAuthority.decode(Data("{}".utf8), now: Date()), .failure(.malformed("undecodable")))
        var wrongSchema = grant()
        wrongSchema.schemaVersion = 99
        XCTAssertEqual(PlanMCPAuthority.decode(try wrongSchema.encoded(), now: Date()),
                       .failure(.malformed("schema_version")))
        let missing = root.appendingPathComponent("absent.json").path
        XCTAssertEqual(PlanMCPAuthority.load(environment: [PlanMCPAuthority.environmentKey: missing]),
                       .failure(.unreadable(missing)))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: try write(grant()))
        XCTAssertEqual(PlanMCPAuthority.load(environment: [PlanMCPAuthority.environmentKey: link.path]),
                       .failure(.unreadable(link.path)), "a descriptor is never followed through a symlink")
    }

    func test_routerRefusesOutsideTheGrantAndUnderABrokenDescriptor() {
        var replies: [String] = []
        var errors: [[Any]] = []
        let args: [String: Any] = ["task_id": "T1", "by": "codex:t1", "project": project.path]
        PlanMCPTools.routeTaskCall("throttle_task_verdict", args.merging(["verdict": "done"]) { $1 },
                                   authority: .success(grant()), { replies.append($0) }, { errors.append($0) })
        XCTAssertEqual(replies.last, "Refused: this runtime was not granted verdict.")
        PlanMCPTools.routeTaskCall("throttle_task_claim", args.merging(["by": "someone-else"]) { $1 },
                                   authority: .success(grant()), { replies.append($0) }, { errors.append($0) })
        XCTAssertEqual(replies.last, "Refused: this runtime speaks as codex:t1, not someone-else.")
        PlanMCPTools.routeTaskCall("throttle_plan_read", ["project": project.path],
                                   authority: .failure(.expired), { replies.append($0) }, { errors.append($0) })
        XCTAssertEqual(replies.last, "Refused: the runtime's authority descriptor has expired.")
        XCTAssertTrue(errors.isEmpty, "a refusal is an answer, not a protocol error")
        PlanMCPTools.routeTaskCall("throttle_plan_read", ["project": project.path],
                                   authority: .success(grant()), { replies.append($0) }, { errors.append($0) })
        XCTAssertFalse(replies.last?.hasPrefix("Refused: this runtime") ?? true, "read is within the grant")
    }
}
