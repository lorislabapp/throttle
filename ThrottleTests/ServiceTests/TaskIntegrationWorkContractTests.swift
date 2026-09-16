@testable import Throttle
import XCTest

final class TaskIntegrationWorkContractTests: XCTestCase {
    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-contract-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "line one\n".write(
            to: repo.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        run(["add", "."])
        run(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testIntegrateRefusesChangesOutsideThePersistedWorkContract() throws {
        let base = sha("HEAD")
        let contract = workContract(allowedChangePaths: ["file.txt"])
        let task = PlanTask(id: "t1", title: "T1", workContract: contract)
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", tasks: [task]))
        try finishTask(store)
        XCTAssertTrue(try verify(store).passed)

        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1",
            in: repo,
            store: store,
            task: task,
            author: "throttle:test"
        )) { error in
            XCTAssertEqual(error as? TaskIntegrationError, .scopeViolation(["task.txt"]))
        }
        XCTAssertEqual(sha("HEAD"), base)
    }

    func testIntegrateRefusesVerificationFromAnEarlierWorkContract() throws {
        let base = sha("HEAD")
        var contract = workContract(allowedChangePaths: ["task.txt"])
        let originalTask = PlanTask(id: "t1", title: "T1", workContract: contract)
        let store = PlanStore(projectRoot: repo)
        var plan = Plan(projectId: "p", title: "P", tasks: [originalTask])
        try store.bootstrap(plan)
        try finishTask(store)
        XCTAssertTrue(try verify(store).passed)
        XCTAssertEqual(
            try store.state(for: "t1").lastCheck?.receipt?.workContractDigest,
            contract.digest
        )

        contract.objective = "Changed after verification"
        plan.tasks[0].workContract = contract
        try write(plan)
        XCTAssertThrowsError(try TaskIntegrationService.integrate(
            taskID: "t1",
            in: repo,
            store: store,
            task: plan.tasks[0],
            author: "throttle:test"
        )) { error in
            XCTAssertEqual(error as? TaskIntegrationError, .refused(.unverified))
        }
        XCTAssertEqual(sha("HEAD"), base)
    }

    private func finishTask(_ store: PlanStore) throws {
        let path = try TaskWorktreeService.create(taskID: "t1", in: repo)
        try "task work\n".write(
            to: path.appendingPathComponent("task.txt"),
            atomically: true,
            encoding: .utf8
        )
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "task"], in: path)
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "codex:a",
            type: .claimed
        ), to: "t1")
        try store.append(TaskEvent(
            seq: 0,
            timestamp: Date(),
            author: "codex:a",
            type: .completed
        ), to: "t1")
    }

    private func verify(_ store: PlanStore) throws -> TaskIntegrationService.Verdict {
        try TaskIntegrationService.verify(
            taskID: "t1",
            in: repo,
            command: "true",
            store: store,
            author: "throttle:test"
        )
    }

    private func workContract(allowedChangePaths: [String]) -> WorkflowWorkContract {
        WorkflowWorkContract(
            revision: 1,
            objective: "Change only approved files.",
            approvedProductReference: "decision:scope-v1",
            requirements: [
                WorkflowRequirement(
                    id: "R1",
                    statement: "Keep the change inside approved paths.",
                    acceptanceCriteria: ["No other path changes."]
                )
            ],
            allowedChangePaths: allowedChangePaths,
            mustPreserve: ["All other paths."],
            exclusions: [],
            platforms: [.macOS],
            baseRevision: sha("HEAD"),
            inputs: [],
            permissionRequirements: [],
            budget: WorkflowBudgetContract()
        )
    }

    private func write(_ plan: Plan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(plan).write(
            to: repo.appendingPathComponent(".throttle/plan.json"),
            options: .atomic
        )
    }

    @discardableResult
    private func run(_ args: [String], in directory: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return String(describing: error) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func sha(_ revision: String) -> String {
        run(["rev-parse", revision]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
