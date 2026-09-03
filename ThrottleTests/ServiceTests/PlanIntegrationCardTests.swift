@testable import Throttle
import XCTest

/// What the card ends up showing, and who it shows it for. Separate from
/// `PlanIntegrationFlowTests` only because that file is at its length limit; these
/// cover the three ways the card used to be silent or wrong — an assessment written
/// into the wrong project, a refusal rendered as an empty space, and one project's
/// run greying out another project's button.
@MainActor
final class PlanIntegrationCardTests: XCTestCase {

    private enum Failure: Error { case noDefaultsSuite }

    private var repo = URL(fileURLWithPath: "/")
    private var suiteName = ""
    private var consent: UserDefaults?
    private var otherRoots: [URL] = []

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-tests-\(UUID().uuidString)", isDirectory: true)
        try initRepository(at: repo)
        suiteName = "plan-integration-card-\(UUID().uuidString)"
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
        // Not `try?`: a launch that throws (a working directory that no longer
        // exists, say) leaves this process holding the pipe's write end, and the read
        // below then blocks for ever with nothing to show for it.
        do { try process.run() } catch { return String(describing: error) }
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

    /// A one-task plan whose task is finished in its own worktree. `file` is what the
    /// task touched, so an assessment can be traced back to the project it came from.
    @discardableResult
    private func plantFinishedTask(in root: URL, verify: String?,
                                   file: String) throws -> URL {
        let store = PlanStore(projectRoot: root)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: verify,
                                 tasks: [PlanTask(id: "t1", title: "T1")]))
        let path = try TaskWorktreeService.create(taskID: "t1", in: root)
        try "task work\n".write(to: path.appendingPathComponent(file),
                                atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work"], in: path)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .claimed), to: "t1")
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a",
                                   type: .completed), to: "t1")
        return path
    }

    private func makeModel(verify: String?) throws -> PlanModel {
        try plantFinishedTask(in: repo, verify: verify, file: "task.txt")
        let model = PlanModel()
        model.verifyConsentDefaults = try consentDefaults()
        model.bind(to: repo)
        return model
    }

    /// A second project holding its own finished `t1` — same id, different plan,
    /// which is the whole hazard — touching a differently named file, so a leaked
    /// assessment names the project it actually came from.
    private func secondProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("card-tests-other-\(UUID().uuidString)", isDirectory: true)
        try initRepository(at: root)
        try plantFinishedTask(in: root, verify: "true", file: "other-task.txt")
        otherRoots.append(root)
        return root
    }
}

// MARK: - Which project an assessment belongs to

extension PlanIntegrationCardTests {

    /// The root-changed guard used to sit *before* `refreshAssessment`, while the
    /// write happens after its own `await`. A rebind inside that window put one
    /// project's assessment into another project's cache — task ids are only unique
    /// inside one plan, so it would have been drawn under a same-named task.
    ///
    /// The started child cannot run while this test body holds the main actor, and
    /// once it does start it suspends immediately on a detached task that spawns half
    /// a dozen git processes — orders of magnitude longer than the yields below. The
    /// assertion holds either way round: whatever lands must not be `repo`'s.
    func test_anAssessmentLandingAfterARebindIsNotWrittenIntoTheNewProject() async throws {
        let model = try makeModel(verify: "true")
        let other = try secondProject()

        let refresh = Task { await model.refreshAssessment(for: "t1") }
        for _ in 0..<200 { await Task.yield() }
        model.bind(to: other)
        await refresh.value

        XCTAssertNotEqual(model.assessment(for: "t1")?.files.map(\.path), ["task.txt"],
                          "that assessment describes the project the model has left")
    }

    /// Binding away drops the caches, errors included — they are keyed by task id,
    /// and task ids mean nothing outside their own plan.
    func test_bindingToAnotherProjectForgetsTheStoredError() async throws {
        let model = try makeModel(verify: "true")
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        run(["checkout", "-q", "--detach"], in: path)
        await model.refreshAssessment(for: "t1")
        XCTAssertNotNil(model.assessmentError(for: "t1"))

        model.bind(to: try secondProject())

        XCTAssertNil(model.assessmentError(for: "t1"))
    }
}

// MARK: - Saying why there is no card

extension PlanIntegrationCardTests {

    /// `refreshAssessment` swallowed every `assess` failure with `try?`, so a worktree
    /// that had wandered off its task branch drew nothing at all: the task is `done`,
    /// the user is looking for the button, and the space where it should be was empty.
    func test_aDetachedWorktreeSaysSoInsteadOfDrawingNothing() async throws {
        let model = try makeModel(verify: "true")
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        run(["checkout", "-q", "--detach"], in: path)

        await model.refreshAssessment(for: "t1")

        XCTAssertNil(model.assessment(for: "t1"), "there is nothing to assess")
        let reason = try XCTUnwrap(model.assessmentError(for: "t1"),
                                   "and the card has something to say about why")
        XCTAssertTrue(reason.contains("not on its own branch"), reason)
    }

    /// And the error is cleared like the caches are: putting the worktree back on its
    /// branch brings the card back rather than pinning the old refusal under it.
    func test_theStoredErrorClearsOnceTheWorktreeIsBackOnItsBranch() async throws {
        let model = try makeModel(verify: "true")
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        run(["checkout", "-q", "--detach"], in: path)
        await model.refreshAssessment(for: "t1")
        XCTAssertNotNil(model.assessmentError(for: "t1"))

        run(["checkout", "-q", "task/t1"], in: path)
        await model.refreshAssessment(for: "t1")

        XCTAssertNotNil(model.assessment(for: "t1"))
        XCTAssertNil(model.assessmentError(for: "t1"))
    }
}

// MARK: - Whose button is greyed out, and why it is disabled

extension PlanIntegrationCardTests {

    /// `integrationStep` was one field on a model that serves whichever project is
    /// bound, so a run in project A disabled project B's Integrate button and refused
    /// its clicks. Honest state, read as a bug.
    func test_aRunInOneProjectLeavesAnotherProjectsButtonAlone() async throws {
        let model = try makeModel(verify: "sleep 2")
        VerifyConsent.grant(project: repo, command: "sleep 2", defaults: try consentDefaults())
        let other = try secondProject()

        async let first: String? = model.integrate(taskID: "t1")
        var spins = 0
        while model.integrationStep == .idle, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        model.bind(to: other)

        XCTAssertEqual(model.integrationStep, .idle,
                       "the other project's card is not greyed out by a run it has no part in")
        let refusal = await model.integrate(taskID: "t1")
        XCTAssertNotEqual(refusal, "An integration is already running.",
                          "and its clicks are not refused either — the guard is per project")

        model.bind(to: repo)
        XCTAssertNotEqual(model.integrationStep, .idle, "while the running one still says so")
        _ = await first
        XCTAssertEqual(model.integrationStep, .idle, "and releases when it finishes")
    }

    /// The card read `isDirty` — the untracked-inclusive view — so build output left
    /// by the last verification disabled the button with no explanation and nothing
    /// the user could do about it from the card. It reads what the service refuses on.
    func test_theCardBlocksOnTrackedChangesOnlyAndAlwaysSaysWhy() {
        let buildOutput = assessment(isDirty: true, hasLooseWork: false, mergeability: .clean)
        XCTAssertFalse(PlanTreeView.blocked(buildOutput),
                       "an untracked artefact is not work, and does not block")
        XCTAssertNil(PlanTreeView.blockReason(buildOutput))

        let realWork = assessment(isDirty: true, hasLooseWork: true, mergeability: .clean)
        XCTAssertTrue(PlanTreeView.blocked(realWork))
        XCTAssertNotNil(PlanTreeView.blockReason(realWork), "a disabled button says why")

        let conflict = assessment(isDirty: false, hasLooseWork: false,
                                  mergeability: .conflicted(["file.txt"]))
        XCTAssertTrue(PlanTreeView.blocked(conflict))
        XCTAssertNotNil(PlanTreeView.blockReason(conflict))
    }

    private func assessment(isDirty: Bool, hasLooseWork: Bool,
                            mergeability: Mergeability) -> Assessment {
        Assessment(baseSHA: "base", taskSHA: "task", behindBy: 0, aheadBy: 1,
                   isDirty: isDirty, hasLooseWork: hasLooseWork, files: [],
                   mergeability: mergeability)
    }
}

// MARK: - What happens to the worktree afterwards

/// The removal is the model's call, not the service's: a task's worktree is also
/// the cwd the cockpit opened that task's session in, and the service cannot see
/// tabs. Both branches are here, because deleting under a live tab and never
/// deleting at all are equally wrong.
extension PlanIntegrationCardTests {

    func test_anIntegratedWorktreeIsRemovedWhenNothingIsLivingInIt() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())
        let path = try TaskWorktreeService.path(for: "t1", in: repo)

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNil(refusal, refusal ?? "")
        XCTAssertEqual(model.state("t1").status, .integrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                       "the worktree went away with the merge")
        XCTAssertNil(model.keptWorktreePath(for: "t1"), "a worktree that is gone needs no words")
    }

    /// `TaskLauncher.LaunchPlan.workingDirectory` *is* this directory, and the
    /// cockpit opens the agent's tab with it as cwd. Deleting it under that tab
    /// leaves the shell with a working directory that no longer exists and makes
    /// every later command in it fail obscurely — so it is kept, and said.
    func test_aWorktreeACockpitSessionIsWorkingInIsKeptAndTheCardSaysSo() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        // A session sitting one level *inside* the worktree, which is as much of a
        // problem as one sitting exactly on it.
        let sessionCWD = path.appendingPathComponent("nested", isDirectory: true)
        model.isDirectoryHeldBySession = { directory in
            sessionCWD.path.hasPrefix(directory.standardizedFileURL.path + "/")
        }

        let refusal = await model.integrate(taskID: "t1")

        XCTAssertNil(refusal, refusal ?? "")
        XCTAssertEqual(model.state("t1").status, .integrated,
                       "keeping the directory never demotes a merge that happened")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "the session's working directory is still there")
        XCTAssertEqual(model.keptWorktreePath(for: "t1"), path.path,
                       "and the card can name the directory that stayed")
    }

    /// The message used to be a note the cleanup wrote, and `bind` clears the caches:
    /// switching projects and back — or relaunching — left the directory on disk with
    /// nothing on the card to explain it. It is read back off disk now, so it comes
    /// back with the card.
    func test_theKeptWorktreeIsStillReportedAfterATabSwitch() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        model.isDirectoryHeldBySession = { $0.standardizedFileURL == path.standardizedFileURL }
        _ = await model.integrate(taskID: "t1")
        XCTAssertNotNil(model.keptWorktreePath(for: "t1"))

        model.bind(to: try secondProject())
        model.bind(to: repo)
        XCTAssertNil(model.keptWorktreePath(for: "t1"), "the caches went with the rebind")

        await model.refreshAssessment(for: "t1")

        XCTAssertEqual(model.keptWorktreePath(for: "t1"), path.path,
                       "and the fact came back, because it was never a memory")
    }

    /// The other direction of the same derivation: remove the directory by hand and
    /// the card stops claiming it is there, with nothing to invalidate.
    func test_theReportStopsTheDayTheDirectoryGoes() async throws {
        let model = try makeModel(verify: "true")
        VerifyConsent.grant(project: repo, command: "true", defaults: try consentDefaults())
        let path = try TaskWorktreeService.path(for: "t1", in: repo)
        model.isDirectoryHeldBySession = { _ in true }
        _ = await model.integrate(taskID: "t1")
        XCTAssertNotNil(model.keptWorktreePath(for: "t1"))

        run(["worktree", "remove", "--force", path.path])
        await model.refreshAssessment(for: "t1")

        XCTAssertNil(model.keptWorktreePath(for: "t1"))
    }

    /// The rule the cockpit hands the model, tested without a cockpit around it.
    func test_aSessionIsFoundWhetherItSitsOnTheDirectoryOrInsideIt() {
        let worktree = URL(fileURLWithPath: "/tmp/wt", isDirectory: true)
        XCTAssertTrue(SessionWorkingDirectory.isSessionWorking(inside: worktree, of: [tab("/tmp/wt")]))
        XCTAssertTrue(SessionWorkingDirectory.isSessionWorking(inside: worktree, of: [tab("/tmp/wt/deep")]))
        XCTAssertFalse(SessionWorkingDirectory.isSessionWorking(inside: worktree, of: [tab("/tmp/other")]),
                       "a sibling is not inside it")
        XCTAssertFalse(SessionWorkingDirectory.isSessionWorking(inside: worktree, of: [tab("/tmp/wt-2")]),
                       "and neither is a directory that merely starts with its name")
        XCTAssertFalse(SessionWorkingDirectory.isSessionWorking(inside: worktree, of: [tab("")]))
    }

    private func tab(_ cwd: String) -> CockpitTab {
        CockpitTab(projectName: "p", cwd: cwd)
    }
}
