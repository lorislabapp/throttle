@testable import Throttle
import XCTest

/// A descriptor can only take rights away. Absent, nothing changes; present,
/// every call is measured against it; broken, every call is refused.
final class PlanMCPAuthorityTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

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
        PlanMCPAuthority(projectRoots: [project], author: "codex:t1", operations: operations, expiresAt: expiresAt)
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

    func test_aPrivateDescriptorLoadsAndNarrowsCalls() throws {
        let path = try write(grant())
        let environment = [PlanMCPAuthority.environmentKey: path]
        let loaded = try XCTUnwrap(try PlanMCPAuthority.load(environment: environment).get())
        XCTAssertEqual(loaded, grant())
        XCTAssertNil(loaded.refusal(project: project.path, author: "codex:t1", operation: .claim))
        XCTAssertNil(loaded.refusal(project: project.path + "/", author: "codex:t1", operation: .read),
                     "a trailing slash is the same project")
        XCTAssertNotNil(loaded.refusal(project: root.path, author: "codex:t1", operation: .claim),
                        "a sibling directory is another project")
        XCTAssertNotNil(loaded.refusal(project: project.path, author: "codex:t2", operation: .claim))
        XCTAssertNotNil(loaded.refusal(project: project.path, author: "codex:t1", operation: .verdict),
                        "verdict was not granted")
    }

    func test_symlinkedProjectResolvesToTheGrantedRoot() throws {
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        XCTAssertNil(grant().refusal(project: link.path, author: "codex:t1", operation: .read))
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
        wrongSchema.schemaVersion = 2
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
