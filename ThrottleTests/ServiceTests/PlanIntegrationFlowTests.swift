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
    /// Extra projects a test bound the model to, removed with `repo`.
    private var otherRoots: [URL] = []

    // The async spellings, not `setUpWithError`: XCTest's throwing overrides are
    // nonisolated, and this suite's stored state belongs to the main actor.
    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
        try initRepository(at: repo)

        suiteName = "plan-integration-flow-\(UUID().uuidString)"
        consent = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        consent?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: repo)
        for root in otherRoots { try? FileManager.default.removeItem(at: root) }
        otherRoots = []
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

    private func initRepository(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"], in: root)
        run(["config", "user.email", "test@example.com"], in: root)
        run(["config", "user.name", "Test"], in: root)
        try "seed\n".write(to: root.appendingPathComponent("file.txt"),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: root)
        run(["commit", "-q", "-m", "seed"], in: root)
    }

    /// A one-task plan whose task is finished in its own worktree, with `verify` as
    /// the plan's check command.
    private func plantFinishedTask(in root: URL, verify: String?) throws {
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: verify,
                                 tasks: [PlanTask(id: "t1", title: "T1")]))
        let path = try TaskWorktreeService.create(taskID: "t1", in: root)
        try "task work\n".write(to: path.appendingPathComponent("task.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work"], in: path)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .claimed), to: "t1")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .completed), to: "t1")
    }

    /// A project holding one finished task in its own worktree, with `verify` as
    /// the plan's check command.
    private func makeModel(verify: String?) throws -> PlanModel {
        try plantFinishedTask(in: repo, verify: verify)
        let model = PlanModel()
        model.verifyConsentDefaults = try consentDefaults()
        model.bind(to: repo)
        return model
    }

    /// A second project the model can be switched to mid-run. It holds its own
    /// finished `t1` — same id, different plan, which is the whole hazard — so a
    /// stray refresh against it would be visible rather than a silent no-op.
    private func secondProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-other-\(UUID().uuidString)", isDirectory: true)
        try initRepository(at: root)
        try plantFinishedTask(in: root, verify: "true")
        otherRoots.append(root)
        return root
    }

    /// Lets the sequence started with `async let` reach its first off-actor step.
    /// Bounded and asserted on state, never on elapsed time.
    private func waitUntilRunning(_ model: PlanModel) async {
        var spins = 0
        while model.integrationStep == .idle, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
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

    /// Only the card gated this before. A task still in review would have run the
    /// project's verify command — minutes of shelling out — for a `checked` event
    /// the projection then rejects, ending in `.unverified`. The guard is in the
    /// model now, and the proof is that the command left no trace.
    func test_integrateRefusesATaskThatIsNotDone() async throws {
        let command = "touch ran-anyway.txt"
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: command,
                                 tasks: [PlanTask(id: "t1", title: "T1", sotaGate: true)]))
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
        VerifyConsent.grant(project: repo, command: command, defaults: try consentDefaults())
        XCTAssertEqual(model.state("t1").status, .review, "gated, so it is not done yet")

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNotNil(refusal)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: path.appendingPathComponent("ran-anyway.txt").path),
                       "the verify command never ran")
        XCTAssertNil(model.state("t1").lastCheck, "and no check was written")
        XCTAssertEqual(model.integrationStep, .idle)
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

// MARK: - Switching tabs while it runs

/// An integration is deliberately minutes long, and `bind` sits in the cockpit's
/// `onChange(of: activeID)` — an ordinary tab switch. These two say what a tab
/// switch is: not a cancellation, and not a licence to write this run's tail into
/// whatever project is bound when it lands.
///
/// The verify command is a short `sleep`, which is only there to hold the window
/// open; every assertion is on published state, none on elapsed time.
extension PlanIntegrationFlowTests {

    /// `bind` used to clear `integrationStep` along with the caches. That re-armed
    /// this model's own `guard integrationStep == .idle` and the card's `disabled`,
    /// so a second click ran `git rebase` in the same worktree as the first — two
    /// processes over one `.git/worktrees/t1/rebase-merge` — and the project's
    /// verify command twice at once.
    func test_aTabSwitchMidIntegrationDoesNotReArmTheButton() async throws {
        let model = try makeModel(verify: "sleep 2")
        VerifyConsent.grant(project: repo, command: "sleep 2", defaults: try consentDefaults())
        let other = try secondProject()

        async let first: String? = model.integrate(taskID: "t1")
        await waitUntilRunning(model)
        XCTAssertNotEqual(model.integrationStep, .idle, "the sequence is in flight")

        model.bind(to: other)
        XCTAssertNotEqual(model.integrationStep, .idle, "binding away cancels nothing")
        model.bind(to: repo)
        XCTAssertNotEqual(model.integrationStep, .idle, "and coming back re-arms nothing")

        let second = await model.integrate(taskID: "t1")
        XCTAssertEqual(second, "An integration is already running.")

        let outcome = await first
        XCTAssertNil(outcome, outcome ?? "")
        XCTAssertEqual(model.integrationStep, .idle, "the run that finished released it")
        XCTAssertEqual(model.state("t1").status, .integrated, "and it merged exactly once")
    }

    /// The other half: a run that lands after the model moved on must not reload a
    /// plan it says nothing about, nor cache its assessment under the same-named
    /// task of another project.
    func test_aRunLandingAfterATabSwitchWritesNothingIntoTheNewProject() async throws {
        let model = try makeModel(verify: "sleep 2")
        VerifyConsent.grant(project: repo, command: "sleep 2", defaults: try consentDefaults())
        let other = try secondProject()

        async let first: String? = model.integrate(taskID: "t1")
        await waitUntilRunning(model)
        model.bind(to: other)
        let outcome = await first

        XCTAssertNil(outcome, outcome ?? "")
        XCTAssertNil(model.assessment(for: "t1"),
                     "the finished run assessed nothing in the project it did not run in")
        XCTAssertEqual(model.state("t1").status, .done, "which is the other project's own t1")
    }
}
