@testable import Throttle
import XCTest

/// What the single "Integrate" button does, tested where it can be: the sequence
/// rebase → verify → merge, and the fact that it stops at the first refusal.
/// SwiftUI rendering is not the coverage here — the chaining is.
///
/// `PlanModel` is `@MainActor`, so this suite is too, and every test awaits the
/// async `integrate`: the verification runs a real command and must never block
/// the actor that draws.
@MainActor
final class PlanIntegrationFlowTests: XCTestCase {

    private enum Failure: Error { case noDefaultsSuite }

    private var repo = URL(fileURLWithPath: "/")
    private var suiteName = ""
    /// Consent is read from injected defaults, never `.standard`: a test suite has
    /// no business granting the user's real Throttle permission to run a command.
    private var consent: UserDefaults?

    // The async spellings, not `setUpWithError`: XCTest's throwing overrides are
    // nonisolated, and this suite's stored state belongs to the main actor.
    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("file.txt"),
                           atomically: true, encoding: .utf8)
        run(["add", "."])
        run(["commit", "-q", "-m", "seed"])

        suiteName = "plan-integration-flow-\(UUID().uuidString)"
        consent = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        consent?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: repo)
    }

    private func consentDefaults() throws -> UserDefaults {
        guard let consent else { throw Failure.noDefaultsSuite }
        return consent
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
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A project holding one finished task in its own worktree, with `verify` as
    /// the plan's check command.
    private func makeModel(verify: String?) throws -> PlanModel {
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: verify,
                                 tasks: [PlanTask(id: "t1", title: "T1")]))
        let path = try TaskWorktreeService.create(taskID: "t1", in: repo)
        try "task work\n".write(to: path.appendingPathComponent("task.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work"], in: path)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .claimed), to: "t1")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .completed), to: "t1")
        let model = PlanModel()
        model.verifyConsentDefaults = try consentDefaults()
        model.bind(to: repo)
        return model
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(name).path)
    }

    // MARK: - The command

    func test_theTaskVerifyCommandOverridesTheProjectOne() throws {
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: "project-level",
                                 tasks: [PlanTask(id: "t1", title: "T1", verify: "task-level")]))
        let model = PlanModel()
        model.bind(to: repo)
        XCTAssertEqual(model.verifyCommand(for: "t1"), "task-level")
    }

    func test_integrateRefusesWithoutAVerifyCommand() async throws {
        let model = try makeModel(verify: nil)
        let refusal = await model.integrate(taskID: "t1")
        XCTAssertNotNil(refusal)
        XCTAssertEqual(model.state("t1").status, .done, "nothing moved")
        XCTAssertEqual(model.integrationStep, .idle, "a refusal leaves no step running")
    }

    // MARK: - Consent

    /// The first click asks; it does not run. The second, after the user allowed
    /// it, runs the whole thing — the prompt must stop blocking once answered.
    func test_integrateAsksForConsentBeforeItRunsAnythingThenStopsAsking() async throws {
        let model = try makeModel(verify: "true")

        let refusal = await model.integrate(taskID: "t1")
        XCTAssertNotNil(refusal)
        XCTAssertEqual(model.pendingVerifyCommand, "true", "the card can name what to allow")
        XCTAssertEqual(model.state("t1").status, .done, "an unallowed command never ran")
        XCTAssertNil(model.state("t1").lastCheck, "and wrote no check")

        model.allowVerifyCommand()
        XCTAssertNil(model.pendingVerifyCommand)

        let second = await model.integrate(taskID: "t1")
        XCTAssertNil(second, second ?? "")
        XCTAssertEqual(model.state("t1").status, .integrated)
    }
}

// MARK: - The sequence

/// Split from the class body to stay under SwiftLint's `type_body_length`; the
/// `private` helpers above stay visible because Swift's `private` reaches
/// same-file extensions of the same type.
extension PlanIntegrationFlowTests {

    func test_integrateRunsTheWholeSequenceOnce() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNil(refusal, refusal ?? "")
        XCTAssertEqual(model.state("t1").status, .integrated)
        XCTAssertNotNil(model.state("t1").integratedSHA)
        XCTAssertEqual(model.state("t1").lastCheck?.passed, true)
        XCTAssertEqual(model.integrationStep, .idle, "the button is clickable again")
        XCTAssertNil(model.assessment(for: "t1"), "an integrated task has nothing left to assess")
    }

    func test_integrateStopsAtAFailingVerification() async throws {
        let model = try makeModel(verify: "exit 1")
        VerifyConsent.grant(project: repo, command: "exit 1", defaults: try consentDefaults())

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNotNil(refusal)
        XCTAssertEqual(model.state("t1").status, .done, "a red check never merges")
        XCTAssertEqual(model.state("t1").lastCheck?.passed, false)
        XCTAssertEqual(model.integrationStep, .idle)
        XCTAssertFalse(exists("task.txt"), "the base branch was left alone")
    }

    /// The rebase is the first step for a reason: a task written before the base
    /// moved still integrates, and the check then runs on the combined tree.
    func test_integrateRebasesABehindTaskBeforeMerging() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())
        try "elsewhere\n".write(to: repo.appendingPathComponent("other.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."])
        run(["commit", "-q", "-m", "base moves"])

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNil(refusal, refusal ?? "")
        XCTAssertEqual(model.state("t1").status, .integrated)
        XCTAssertTrue(exists("task.txt"), "the task's work landed")
        XCTAssertTrue(exists("other.txt"), "and the base's own commit survived it")
    }

    // MARK: - What the card reads

    func test_theAssessmentIsCachedRatherThanReadOnEveryDraw() async throws {
        let model = try makeModel(verify: "true")
        XCTAssertNil(model.assessment(for: "t1"), "nothing shells out until it is asked to")

        await model.refreshAssessment(for: "t1")

        let assessment = try XCTUnwrap(model.assessment(for: "t1"))
        XCTAssertEqual(assessment.files.map(\.path), ["task.txt"])
        XCTAssertEqual(assessment.mergeability, .clean)
        XCTAssertEqual(assessment.aheadBy, 1)
    }

    func test_theDiffIsFetchedOnlyWhenItIsOpened() async throws {
        let model = try makeModel(verify: "true")
        XCTAssertEqual(model.integrationDiff(for: "t1"), "")

        await model.refreshDiff(for: "t1")

        XCTAssertTrue(model.integrationDiff(for: "t1").contains("task.txt"))
    }
}
