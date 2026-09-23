@testable import Throttle
import XCTest

final class TaskLauncherBudgetTests: XCTestCase {
    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-budget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".throttle"),
            withIntermediateDirectories: true
        )
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "test@example.com"])
        git(["config", "user.name", "Test"])
        try "seed\n".write(
            to: repo.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        git(["add", "."])
        git(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testConfiguredBudgetIsReservedAndPinnedToTheClaimBeforeLaunch() throws {
        try writeBudgetedPlan(exactTokens: 40)
        try bootstrapBudget(total: 100)
        let launch = try TaskLauncher.prepare(
            taskID: "T1.1",
            runtime: .codex,
            repo: repo,
            author: "codex:a",
            base: "main"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: launch.authorityDescriptor) }

        let admission = try XCTUnwrap(launch.budgetAdmission)
        let claim = try XCTUnwrap(PlanStore(projectRoot: repo).events(for: "T1.1").events.first)
        XCTAssertEqual(claim.budgetReservationID, admission.reservation.id)
        XCTAssertEqual(claim.budgetLedgerRevision, admission.ledgerRevision)
        XCTAssertEqual(admission.externalEnforcement, .unavailable)
        XCTAssertTrue(launch.kickoff.contains("External enforcement: unavailable"))
    }

    func testConfiguredBudgetRefusesUnknownAmountBeforeCreatingWorktree() throws {
        try writeBudgetedPlan(exactTokens: nil)
        try bootstrapBudget(total: 100)
        let path = try TaskWorktreeService.path(for: "T1.1", in: repo)

        XCTAssertThrowsError(try TaskLauncher.prepare(
            taskID: "T1.1",
            runtime: .codex,
            repo: repo,
            author: "codex:a",
            base: "main"
        )) { error in
            XCTAssertEqual(
                error as? TaskLauncher.LaunchError,
                .budget(.unknownBudget(.frontierTokens))
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(try PlanStore(projectRoot: repo).events(for: "T1.1").events.isEmpty)
        XCTAssertTrue(try BudgetAdmissionStore(projectRoot: repo).snapshot().reservations.isEmpty)
    }

    func testLaunchFailureReleasesTheReservationItJustCreated() throws {
        try writeBudgetedPlan(exactTokens: 40, baseRevision: String(repeating: "b", count: 40))
        try bootstrapBudget(total: 100)

        XCTAssertThrowsError(try TaskLauncher.prepare(
            taskID: "T1.1",
            runtime: .codex,
            repo: repo,
            author: "codex:a",
            base: "main"
        ))
        let reservations = try BudgetAdmissionStore(projectRoot: repo).snapshot().reservations
        XCTAssertEqual(reservations.count, 1)
        XCTAssertEqual(reservations.first?.state, .released)
    }

    private func bootstrapBudget(total: Int) throws {
        let now = Date()
        try BudgetAdmissionStore(projectRoot: repo).bootstrap(
            capacities: [BudgetCapacity(
                resource: .frontierTokens,
                total: total,
                protectedForVerification: 20,
                protectedForRelease: 20
            )],
            periodStartsAt: now.addingTimeInterval(-60),
            periodEndsAt: now.addingTimeInterval(3_600)
        )
    }

    private func writeBudgetedPlan(exactTokens: Int?, baseRevision: String? = nil) throws {
        let tokenLimit = exactTokens.map {
            WorkflowBudgetAmount(knowledge: .exact, value: $0, unit: "tokens")
        } ?? .unknown(unit: "tokens")
        let task = PlanTask(
            id: "T1.1",
            title: "Budgeted",
            workContract: WorkflowWorkContract(
                revision: 1,
                objective: "Launch within budget",
                approvedProductReference: "decision:budget",
                requirements: [WorkflowRequirement(
                    id: "R1",
                    statement: "Reserve first",
                    acceptanceCriteria: ["The hold is durable"]
                )],
                allowedChangePaths: ["Throttle/"],
                mustPreserve: ["Protected reserves"],
                exclusions: [],
                platforms: [.macOS],
                baseRevision: baseRevision ?? gitOutput(["rev-parse", "HEAD"]),
                inputs: [],
                permissionRequirements: [],
                budget: WorkflowBudgetContract(tokenLimit: tokenLimit)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Plan(projectId: "p", title: "Budget", tasks: [task])).write(
            to: repo.appendingPathComponent(".throttle/plan.json"),
            options: .atomic
        )
    }

    private func git(_ args: [String]) {
        _ = gitOutput(args)
    }

    private func gitOutput(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
