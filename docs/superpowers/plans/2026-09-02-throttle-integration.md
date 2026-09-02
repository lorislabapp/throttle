# Throttle Integration (lot F) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Relire le diff d'une tâche terminée, vérifier qu'elle tient sur la base courante, et l'intégrer sur un clic — jamais sans.

**Architecture:** Un service pur (`TaskIntegrationService`) qui parle à git par `Process`, exactement comme `TaskWorktreeService`. Il évalue (`assess`), rebase, vérifie, puis fusionne en fast-forward. Deux nouveaux événements (`checked`, `integrated`) entrent dans le log append-only du lot A; la projection les applique sans passer par la propriété d'une tâche, parce que c'est Throttle qui les écrit, pas un agent. L'UI est une carte de plus dans l'inspecteur de `PlanTreeView`.

**Tech Stack:** Swift 6, SwiftUI, XCTest, git ≥ 2.38 via `/usr/bin/env git`, XcodeGen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-09-02-throttle-integration-design.md`

## Global Constraints

- Branche de travail: `feat/plan-store`, worktree `/Users/kevinnadjarian/GitHub/Throttle/.claude/worktrees/plan-store`.
- Aucune écriture sur la branche de base sans clic humain. Aucun merge automatique, aucun push, aucune PR.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` sur la cible de test — un warning casse le build.
- Les nouveaux fichiers sous `Throttle/Services/` et `ThrottleTests/ServiceTests/` sont pris automatiquement par XcodeGen (`sources: - path: …`). Ne pas éditer `project.yml`.
- Commande de test: `xcodebuild test -project Throttle.xcodeproj -scheme Throttle -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/claude-501/-Users-kevinnadjarian-GitHub-Throttle/f97ebbd2-2d92-402c-9636-a105c092f6de/scratchpad/DD -skipPackagePluginValidation -skipMacroValidation -only-testing:ThrottleTests/<Suite>`
- `WindowCalculatorTests.test_weeklySonnet_filtersByModel` et `…_resetIgnoresNonSonnetEvents` échouent **déjà** sur cette branche, sans rapport avec ce lot. Ne pas les corriger ici, ne pas les compter comme une régression.
- Tout test git tourne sur un dépôt jetable créé dans `FileManager.default.temporaryDirectory`, jamais sur le repo de l'utilisateur.
- Style des messages de commit du repo: `[throttle] feat: …` / `[throttle] fix: …`, corps en anglais, expliquant ce qui a tranché la décision.

---

### Task 1: Le vocabulaire — `checked`, `integrated`, et ce qu'ils autorisent

**Files:**
- Modify: `Throttle/Models/PlanModels.swift`
- Modify: `Throttle/Services/PlanProjection.swift`
- Modify: `Throttle/Services/PlanMCPTools.swift:176-181`
- Test: `ThrottleTests/ServiceTests/PlanProjectionTests.swift`

**Interfaces:**
- Consumes: `PlanTask`, `TaskEvent`, `TaskState`, `PlanProjection.project(task:events:chainValid:)` (existants).
- Produces:
  - `TaskEventType.checked`, `TaskEventType.integrated`
  - `TaskStatus.integrated`
  - `TaskEvent.ok: Bool?`
  - `Plan.verify: String?`, `PlanTask.verify: String?`
  - `struct TaskCheck: Codable, Sendable, Equatable { let ok: Bool; let stamp: String; let at: Date }`
  - `TaskState.lastCheck: TaskCheck?`, `TaskState.integratedSHA: String?`
  - `PlanProjection.isFinished(_ status: TaskStatus) -> Bool`

- [ ] **Step 1: Écrire les tests qui échouent**

Ajouter à `ThrottleTests/ServiceTests/PlanProjectionTests.swift`. Ce fichier a deux helpers, et deux seulement: `at(_ seconds: Int) -> Date` et `task(_ id:parent:order:dependsOn:sotaGate:)`. Les événements s'y écrivent en toutes lettres, `TaskEvent(seq:timestamp:author:type:…)` — garder ce style.

```swift
// MARK: - Lot F: checked / integrated

func testCheckedIsAcceptedOnADoneTaskWhoeverWroteIt() {
    let projected = PlanProjection.project(task: task("T1"), events: [
        TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
        TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed),
        TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .checked,
                  ref: "abc+def", ok: true)
    ])
    XCTAssertTrue(projected.rejected.isEmpty, "Throttle's own check is not an agent report")
    XCTAssertEqual(projected.lastCheck?.stamp, "abc+def")
    XCTAssertEqual(projected.lastCheck?.ok, true)
    XCTAssertEqual(projected.status, .done, "a check does not move the task")
}

func testCheckedIsRefusedBeforeTheTaskIsDone() {
    let projected = PlanProjection.project(task: task("T1"), events: [
        TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
        TaskEvent(seq: 2, timestamp: at(1), author: "throttle:app", type: .checked,
                  ref: "abc+def", ok: true)
    ])
    XCTAssertEqual(projected.rejected.first?.reason, .terminal)
    XCTAssertNil(projected.lastCheck)
}

func testIntegratedMovesADoneTaskAndIsItselfTerminal() {
    let projected = PlanProjection.project(task: task("T1"), events: [
        TaskEvent(seq: 1, timestamp: at(0), author: "codex:a", type: .claimed),
        TaskEvent(seq: 2, timestamp: at(1), author: "codex:a", type: .completed),
        TaskEvent(seq: 3, timestamp: at(2), author: "throttle:app", type: .integrated,
                  ref: "deadbeef"),
        TaskEvent(seq: 4, timestamp: at(3), author: "codex:a", type: .progress, pct: 50)
    ])
    XCTAssertEqual(projected.status, .integrated)
    XCTAssertEqual(projected.integratedSHA, "deadbeef")
    XCTAssertEqual(projected.rejected.last?.reason, .terminal,
                   "nothing follows an integration")
}

func testIntegratedDependencyDoesNotBlockItsDependent() {
    let plan = Plan(projectId: "p", title: "P", tasks: [
        task("A"),
        task("B", dependsOn: ["A"])
    ])
    var integrated = TaskState()
    integrated.status = .integrated
    let states = PlanProjection.resolve(plan: plan, leafStates: ["A": integrated])
    XCTAssertEqual(states["B"]?.status, .pending,
                   "an integrated dependency is finished, so B is not blocked")
}

func testRollupCountsIntegratedChildrenAsFinished() {
    let plan = Plan(projectId: "p", title: "P", tasks: [
        task("phase"),
        task("A", parent: "phase"),
        task("B", parent: "phase")
    ])
    var done = TaskState(); done.status = .done
    var integrated = TaskState(); integrated.status = .integrated
    let states = PlanProjection.resolve(plan: plan, leafStates: ["A": done, "B": integrated])
    XCTAssertEqual(states["phase"]?.status, .done)
}
```

- [ ] **Step 2: Lancer les tests pour les voir échouer**

Run: `xcodebuild test … -only-testing:ThrottleTests/PlanProjectionTests`
Expected: échec de compilation — `checked`, `integrated`, `ok:`, `lastCheck` n'existent pas.

- [ ] **Step 3: Étendre le modèle**

Dans `Throttle/Models/PlanModels.swift`:

```swift
enum TaskEventType: String, Codable, Sendable {
    case claimed, progress, evidence, blocked, unblocked, completed, failed, released
    case verified, rejected
    /// Written by Throttle, never by an agent: the verification it ran itself, and
    /// the fast-forward it performed. They are facts about a finished task, so they
    /// do not go through ownership.
    case checked, integrated
}
```

Ajouter à `TaskEvent` la propriété stockée `var ok: Bool?`, son paramètre d'init (après `missionID`, valeur par défaut `nil`), et sa clé dans `CodingKeys` (`case ok`). Ajouter dans l'init décodeur manuel s'il en existe un pour `TaskEvent`; sinon la synthèse suffit.

```swift
enum TaskStatus: String, Codable, Sendable {
    case pending, blocked, claimed, running, review, done, failed, integrated
}

/// The verification Throttle ran, stamped with the two SHAs it was true for. It
/// stops being green on its own the moment either side moves — which is the merge
/// queue's guarantee without the queue.
struct TaskCheck: Codable, Sendable, Equatable {
    let ok: Bool
    let stamp: String
    let at: Date
}
```

Dans `TaskState`, ajouter:

```swift
var lastCheck: TaskCheck?
var integratedSHA: String?
```

Dans `Plan`, ajouter `var verify: String?` avec sa `CodingKey` et, dans l'init décodeur manuel, `verify = try box.decodeIfPresent(String.self, forKey: .verify)`. L'init mémberwise devient exactement:

```swift
init(schema: Int = 1, projectId: String, title: String,
     verify: String? = nil, tasks: [PlanTask])
```

— `verify` avant `tasks`, parce que les tests appellent `Plan(projectId:title:verify:tasks:)`.

Dans `PlanTask`, ajouter de même `var verify: String?` (paramètre d'init après `sotaGate`, défaut `nil`, clé, et décodage tolérant `decodeIfPresent`).

- [ ] **Step 4: Étendre la projection**

Dans `Throttle/Services/PlanProjection.swift`:

```swift
/// A task whose work has landed, whichever end of the pipeline it stopped at.
/// Dependencies and rollups ask this rather than comparing to `.done`, so an
/// integrated task does not silently un-satisfy what it unblocked.
static func isFinished(_ status: TaskStatus) -> Bool {
    status == .done || status == .integrated
}

private static func isTerminal(_ status: TaskStatus) -> Bool {
    switch status {
    case .done, .failed, .integrated: return true
    case .pending, .blocked, .claimed, .running, .review: return false
    }
}
```

Dans `rejection(for:given:)`, insérer juste après le contrôle `outOfOrder` et **avant** `isTerminal`:

```swift
// Throttle's own bookkeeping on a finished task. Neither is an agent's report,
// so neither goes through ownership — and neither is accepted before the task
// is actually done.
if event.type == .checked || event.type == .integrated {
    return state.status == .done ? nil : .terminal
}
```

Dans `apply(_:to:gated:)`, ajouter les deux cas au `switch` (et les retirer du `case .claimed, .progress, …` s'ils y ont été ajoutés par erreur):

```swift
case .checked:
    state.lastCheck = TaskCheck(ok: event.ok ?? false,
                                stamp: event.ref ?? "",
                                at: event.timestamp)

case .integrated:
    state.status = .integrated
    state.integratedSHA = event.ref
```

Dans `applyDependencyBlock`, remplacer la comparaison de statut:

```swift
guard let unmet = task.dependsOn.first(where: { !isFinished(states[$0]?.status ?? .pending) })
else { return }
```

Dans `rollupStatus`, remplacer la première ligne:

```swift
if children.allSatisfy({ isFinished($0.status) }) { return .done }
```

et, dans le contrôle `blocked` plus bas, remplacer `$0.status == .blocked || $0.status == .done` par `$0.status == .blocked || isFinished($0.status)`.

- [ ] **Step 5: Interdire les deux événements aux agents**

Dans `Throttle/Services/PlanMCPTools.swift`, remplacer le `guard` d'entrée de `eventText`:

```swift
guard let eventType = TaskEventType(rawValue: request.type),
      eventType != .claimed, eventType != .checked, eventType != .integrated else {
    return "Refused: unknown event type '\(request.type)'."
        + " Use throttle_task_claim to take a task; checks and integrations are Throttle's to write."
}
```

- [ ] **Step 6: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/PlanProjectionTests` puis `-only-testing:ThrottleTests/PlanMCPToolsTests` et `-only-testing:ThrottleTests/PlanStoreTests`
Expected: PASS partout. Les suites existantes ne doivent pas bouger.

- [ ] **Step 7: Commit**

```bash
git add Throttle/Models/PlanModels.swift Throttle/Services/PlanProjection.swift \
        Throttle/Services/PlanMCPTools.swift ThrottleTests/ServiceTests/PlanProjectionTests.swift
git commit -m "[throttle] feat: two events only Throttle may write"
```

---

### Task 2: `assess` — lire une tâche sans jamais la salir

**Files:**
- Create: `Throttle/Services/TaskIntegrationService.swift`
- Test: `ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `TaskWorktreeService.path(for:in:)`, `TaskWorktreeService.branchName(for:)` (`internal`, accessibles depuis le module).
- Produces:
  ```swift
  enum TaskIntegrationError: Error, Equatable {
      case noWorktree(String), gitFailed(String)
      case refused(Refusal)
      enum Refusal: String, Sendable { case dirty, behind, unverified, ungated }
  }
  struct FileChange: Sendable, Equatable { let path: String; let added: Int; let removed: Int }
  enum Mergeability: Sendable, Equatable { case clean, conflicted([String]), unknown }
  struct Assessment: Sendable, Equatable {
      let baseSHA: String, taskSHA: String
      let behindBy: Int, aheadBy: Int
      let isDirty: Bool
      let files: [FileChange]
      let mergeability: Mergeability
      var stamp: String { "\(taskSHA)+\(baseSHA)" }
  }
  enum TaskIntegrationService {
      static func assess(taskID: String, in repo: URL) throws -> Assessment
      static func diff(taskID: String, in repo: URL) throws -> String
  }
  ```

- [ ] **Step 1: Écrire les tests qui échouent**

Créer `ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift`. Le `setUp`/`run` sont copiés de `TaskWorktreeServiceTests` — même dépôt jetable, mêmes raisons.

```swift
@testable import Throttle
import XCTest

/// Integration writes to the base branch, so every test here runs against a real
/// throwaway repository: what matters is which refusals actually hold when git
/// disagrees with us.
final class TaskIntegrationServiceTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("integration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "line one\n".write(to: repo.appendingPathComponent("file.txt"),
                               atomically: true, encoding: .utf8)
        run(["add", "."])
        run(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
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

    /// A worktree for `id` holding one commit that writes `contents` to `file`.
    @discardableResult
    private func worktree(_ id: String, file: String = "file.txt",
                          contents: String) throws -> URL {
        let path = try TaskWorktreeService.create(taskID: id, in: repo)
        try contents.write(to: path.appendingPathComponent(file),
                           atomically: true, encoding: .utf8)
        run(["add", "."], in: path)
        run(["commit", "-q", "-m", "work on \(id)"], in: path)
        return path
    }

    private func headSHA(_ directory: URL? = nil) -> String {
        run(["rev-parse", "HEAD"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - assess

    func test_assess_reportsFilesAndAheadCount() throws {
        try worktree("t1", contents: "line one\nline two\n")
        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)
        XCTAssertEqual(assessment.aheadBy, 1)
        XCTAssertEqual(assessment.behindBy, 0)
        XCTAssertFalse(assessment.isDirty)
        XCTAssertEqual(assessment.files, [FileChange(path: "file.txt", added: 1, removed: 0)])
        XCTAssertEqual(assessment.mergeability, .clean)
    }

    func test_assess_namesTheConflictingFileWithoutTouchingTheWorktree() throws {
        let path = try worktree("t1", contents: "task side\n")
        try "base side\n".write(to: repo.appendingPathComponent("file.txt"),
                                atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "base moves"])

        let before = headSHA(path)
        let assessment = try TaskIntegrationService.assess(taskID: "t1", in: repo)

        XCTAssertEqual(assessment.mergeability, .conflicted(["file.txt"]))
        XCTAssertEqual(assessment.behindBy, 1)
        XCTAssertEqual(headSHA(path), before, "assessing must not move the worktree")
        XCTAssertTrue(run(["status", "--porcelain"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "assessing must not dirty the worktree")
    }

    func test_assess_seesUncommittedWork() throws {
        let path = try worktree("t1", contents: "line one\nline two\n")
        try "scratch\n".write(to: path.appendingPathComponent("notes.txt"),
                              atomically: true, encoding: .utf8)
        XCTAssertTrue(try TaskIntegrationService.assess(taskID: "t1", in: repo).isDirty)
    }

    func test_assess_refusesWhenThereIsNoWorktree() {
        XCTAssertThrowsError(try TaskIntegrationService.assess(taskID: "nope", in: repo)) {
            XCTAssertEqual($0 as? TaskIntegrationError, .noWorktree("nope"))
        }
    }

    func test_diff_returnsTheTextAgainstTheMergeBase() throws {
        try worktree("t1", contents: "line one\nline two\n")
        let text = try TaskIntegrationService.diff(taskID: "t1", in: repo)
        XCTAssertTrue(text.contains("+line two"))
    }
}
```

- [ ] **Step 2: Lancer pour voir l'échec**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: échec de compilation — `TaskIntegrationService` n'existe pas.

- [ ] **Step 3: Écrire le service**

Créer `Throttle/Services/TaskIntegrationService.swift`:

```swift
import Foundation

enum TaskIntegrationError: Error, Equatable {
    case noWorktree(String)
    case gitFailed(String)
    /// A guard that held. Rendered to the user as-is, so each case says which one.
    case refused(Refusal)

    enum Refusal: String, Sendable {
        case dirty, behind, unverified, ungated
    }
}

struct FileChange: Sendable, Equatable {
    let path: String
    let added: Int
    let removed: Int
}

/// What a merge would do, computed without performing one.
enum Mergeability: Sendable, Equatable {
    case clean
    case conflicted([String])
    /// git is too old to answer without writing something. Saying so is better
    /// than guessing on the user's behalf.
    case unknown
}

struct Assessment: Sendable, Equatable {
    let baseSHA: String
    let taskSHA: String
    /// Commits the base has that the task branch does not — what a rebase would replay onto.
    let behindBy: Int
    let aheadBy: Int
    let isDirty: Bool
    let files: [FileChange]
    let mergeability: Mergeability

    /// The two SHAs a verification was true for. A check is green only while both
    /// still hold, so integrating one task stales every other check by itself.
    var stamp: String { "\(taskSHA)+\(baseSHA)" }
}

/// Reads a finished task's worktree, and — only on an explicit call — rebases,
/// verifies, and fast-forwards it into the base branch.
///
/// Reading never writes: `assess` computes the merge in git's object database and
/// leaves the worktree at the exact SHA the agent left it on.
enum TaskIntegrationService {

    // MARK: - Assess

    static func assess(taskID: String, in repo: URL) throws -> Assessment {
        let worktree = try existingWorktree(taskID, in: repo)
        let base = try sha("HEAD", in: repo)
        let task = try sha("HEAD", in: worktree)

        let dirty = !git(["status", "--porcelain"], in: worktree).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let ahead = count(["rev-list", "--count", "\(base)..\(task)"], in: repo)
        let behind = count(["rev-list", "--count", "\(task)..\(base)"], in: repo)

        return Assessment(baseSHA: base, taskSHA: task,
                          behindBy: behind, aheadBy: ahead, isDirty: dirty,
                          files: numstat(base: base, task: task, in: repo),
                          mergeability: mergeability(base: base, task: task, in: repo))
    }

    static func diff(taskID: String, in repo: URL) throws -> String {
        _ = try existingWorktree(taskID, in: repo)
        let branch = try TaskWorktreeService.branchName(for: taskID)
        return git(["diff", "HEAD...\(branch)"], in: repo).output
    }

    /// `merge-tree --write-tree` writes the merged tree into the object database
    /// and nothing into the worktree or the index, so a task can be read while its
    /// agent is still looking at it. It needs git 2.38; older git gets `.unknown`
    /// rather than a guess.
    private static func mergeability(base: String, task: String, in repo: URL) -> Mergeability {
        let result = git(["merge-tree", "--write-tree", "--name-only", base, task], in: repo)
        if result.ok { return .clean }
        let lines = result.output.split(separator: "\n").map(String.init)
        guard lines.count > 1 else { return .unknown }
        // First line is the tree OID; the rest are the conflicting paths.
        let paths = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? .unknown : .conflicted(Array(paths))
    }

    private static func numstat(base: String, task: String, in repo: URL) -> [FileChange] {
        git(["diff", "--numstat", "\(base)...\(task)"], in: repo).output
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { return nil }
                // "-" in place of a count means a binary file.
                return FileChange(path: String(parts[2]),
                                  added: Int(parts[0]) ?? 0,
                                  removed: Int(parts[1]) ?? 0)
            }
    }

    // MARK: - git

    private static func existingWorktree(_ taskID: String, in repo: URL) throws -> URL {
        let path = try TaskWorktreeService.path(for: taskID, in: repo)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw TaskIntegrationError.noWorktree(taskID)
        }
        return path
    }

    private static func sha(_ rev: String, in directory: URL) throws -> String {
        let result = git(["rev-parse", rev], in: directory)
        guard result.ok else { throw TaskIntegrationError.gitFailed(result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func count(_ args: [String], in directory: URL) -> Int {
        Int(git(args, in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    @discardableResult
    static func git(_ args: [String], in directory: URL) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(bytes: data, encoding: .utf8) ?? "")
        } catch {
            return (false, String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/TaskIntegrationService.swift \
        ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift
git commit -m "[throttle] feat: read a finished task without touching it"
```

---

### Task 3: `rebase` — et l'annuler proprement quand ça conflit

**Files:**
- Modify: `Throttle/Services/TaskIntegrationService.swift`
- Test: `ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `assess`, `existingWorktree`, `git` (Task 2).
- Produces: `static func rebase(taskID: String, in repo: URL) throws -> Assessment`

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
// MARK: - rebase

func test_rebase_replaysTheTaskOnTheAdvancedBase() throws {
    try worktree("t1", file: "task.txt", contents: "task work\n")
    try "base work\n".write(to: repo.appendingPathComponent("base.txt"),
                            atomically: true, encoding: .utf8)
    run(["add", "."]); run(["commit", "-q", "-m", "base moves"])

    let after = try TaskIntegrationService.rebase(taskID: "t1", in: repo)
    XCTAssertEqual(after.behindBy, 0, "the task now sits on top of the base")
    XCTAssertEqual(after.aheadBy, 1)
    XCTAssertEqual(after.mergeability, .clean)
}

func test_rebase_abortsAndRestoresTheOriginalSHAOnConflict() throws {
    let path = try worktree("t1", contents: "task side\n")
    try "base side\n".write(to: repo.appendingPathComponent("file.txt"),
                            atomically: true, encoding: .utf8)
    run(["add", "."]); run(["commit", "-q", "-m", "base moves"])
    let before = headSHA(path)

    XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo))
    XCTAssertEqual(headSHA(path), before, "an aborted rebase leaves the SHA where it was")
    // `.git` is a file inside a worktree, so probing for a `rebase-merge` directory
    // there would pass no matter what. git's own status is the honest witness.
    XCTAssertFalse(run(["status"], in: path).contains("rebase in progress"),
                   "no rebase is left half-done")
    XCTAssertTrue(run(["status", "--porcelain"], in: path)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

func test_rebase_refusesADirtyWorktree() throws {
    let path = try worktree("t1", file: "task.txt", contents: "task work\n")
    try "scratch\n".write(to: path.appendingPathComponent("notes.txt"),
                          atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try TaskIntegrationService.rebase(taskID: "t1", in: repo)) {
        XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
    }
}
```

- [ ] **Step 2: Lancer pour voir l'échec**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: échec de compilation — `rebase` n'existe pas.

- [ ] **Step 3: Implémenter**

Ajouter à `TaskIntegrationService`, sous une marque `// MARK: - Rebase`:

```swift
/// Replays the task's commits on top of the current base, inside the task's own
/// worktree. Refuses to touch a worktree holding uncommitted work, and aborts at
/// the first conflict so a failure leaves the agent's state exactly as it was.
@discardableResult
static func rebase(taskID: String, in repo: URL) throws -> Assessment {
    let worktree = try existingWorktree(taskID, in: repo)
    let before = try assess(taskID: taskID, in: repo)
    guard !before.isDirty else { throw TaskIntegrationError.refused(.dirty) }
    guard before.behindBy > 0 else { return before }

    let result = git(["rebase", before.baseSHA], in: worktree)
    guard result.ok else {
        git(["rebase", "--abort"], in: worktree)
        throw TaskIntegrationError.gitFailed(result.output)
    }
    return try assess(taskID: taskID, in: repo)
}
```

- [ ] **Step 4: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Throttle/Services/TaskIntegrationService.swift \
        ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift
git commit -m "[throttle] feat: a rebase that leaves nothing behind when it fails"
```

---

### Task 4: `verify` — exécuter la commande du projet, une fois qu'elle est consentie

**Files:**
- Create: `Throttle/Services/VerifyConsent.swift`
- Modify: `Throttle/Services/TaskIntegrationService.swift`
- Test: `ThrottleTests/ServiceTests/VerifyConsentTests.swift`
- Test: `ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `PlanStore.append(_:to:)`, `Assessment.stamp` (Tasks 1–2).
- Produces:
  ```swift
  enum VerifyConsent {
      static func key(project: URL, command: String) -> String
      static func isGranted(project: URL, command: String, defaults: UserDefaults = .standard) -> Bool
      static func grant(project: URL, command: String, defaults: UserDefaults = .standard)
  }
  extension TaskIntegrationService {
      struct Verdict: Sendable, Equatable { let ok: Bool; let output: String; let stamp: String }
      static func verify(taskID: String, in repo: URL, command: String,
                         timeout: TimeInterval = 900, store: PlanStore?, author: String) throws -> Verdict
  }
  ```

- [ ] **Step 1: Écrire les tests du consentement**

Créer `ThrottleTests/ServiceTests/VerifyConsentTests.swift`:

```swift
@testable import Throttle
import XCTest

/// The verify command comes out of a file in the repo, so it is shell that a
/// stranger may have written. These tests pin the one rule that matters: it never
/// runs before someone said yes to that exact string.
final class VerifyConsentTests: XCTestCase {

    private var defaults = UserDefaults.standard
    private let project = URL(fileURLWithPath: "/tmp/some-project")

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "verify-consent-\(UUID().uuidString)")!
    }

    func test_aCommandIsNotGrantedUntilItIsGranted() {
        XCTAssertFalse(VerifyConsent.isGranted(project: project, command: "swift test",
                                               defaults: defaults))
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertTrue(VerifyConsent.isGranted(project: project, command: "swift test",
                                              defaults: defaults))
    }

    func test_changingTheCommandRevokesTheGrant() {
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertFalse(VerifyConsent.isGranted(project: project, command: "swift test && curl evil.sh",
                                               defaults: defaults))
    }

    func test_grantsDoNotCrossProjects() {
        VerifyConsent.grant(project: project, command: "swift test", defaults: defaults)
        XCTAssertFalse(VerifyConsent.isGranted(project: URL(fileURLWithPath: "/tmp/other"),
                                               command: "swift test", defaults: defaults))
    }
}
```

- [ ] **Step 2: Lancer pour voir l'échec**

Run: `xcodebuild test … -only-testing:ThrottleTests/VerifyConsentTests`
Expected: échec de compilation — `VerifyConsent` n'existe pas.

- [ ] **Step 3: Écrire `VerifyConsent`**

Créer `Throttle/Services/VerifyConsent.swift`:

```swift
import CryptoKit
import Foundation

/// Remembers that the user agreed to run one exact command in one project.
///
/// `.throttle/plan.json` is a file in the repository, so its `verify` command is
/// shell written by whoever wrote the repository. Cloning a project and opening it
/// must not run what it asks for; the grant is keyed by the command's hash, so
/// editing the command asks again.
enum VerifyConsent {

    private static let storageKey = "planVerifyConsent"

    static func key(project: URL, command: String) -> String {
        let material = project.standardizedFileURL.path + "\u{0}" + command
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isGranted(project: URL, command: String,
                          defaults: UserDefaults = .standard) -> Bool {
        let granted = defaults.array(forKey: storageKey) as? [String] ?? []
        return granted.contains(key(project: project, command: command))
    }

    static func grant(project: URL, command: String, defaults: UserDefaults = .standard) {
        var granted = defaults.array(forKey: storageKey) as? [String] ?? []
        let key = key(project: project, command: command)
        guard !granted.contains(key) else { return }
        granted.append(key)
        defaults.set(granted, forKey: storageKey)
    }
}
```

- [ ] **Step 4: Écrire les tests de `verify`**

Ajouter à `TaskIntegrationServiceTests.swift`:

```swift
// MARK: - verify

private func store() -> PlanStore {
    let store = PlanStore(projectRoot: repo)
    try? store.bootstrap(Plan(projectId: "p", title: "P",
                              tasks: [PlanTask(id: "t1", title: "T1")]))
    return store
}

private func finishTask(_ id: String, in store: PlanStore) throws {
    try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .claimed), to: id)
    try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .completed), to: id)
}

func test_verify_recordsAGreenCheckStampedWithBothSHAs() throws {
    try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)

    let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                                    store: store, author: "throttle:test")
    XCTAssertTrue(verdict.ok)
    let state = try store.state(for: "t1")
    XCTAssertEqual(state.lastCheck?.ok, true)
    XCTAssertEqual(state.lastCheck?.stamp, verdict.stamp)
    XCTAssertEqual(state.status, .done, "verifying does not finish a task")
}

func test_verify_recordsAFailureWithItsOutput() throws {
    try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)

    let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo,
                                                    command: "echo boom >&2; exit 3",
                                                    store: store, author: "throttle:test")
    XCTAssertFalse(verdict.ok)
    XCTAssertTrue(verdict.output.contains("boom"))
    XCTAssertEqual(try store.state(for: "t1").lastCheck?.ok, false)
}

func test_verify_runsInsideTheWorktreeNotTheRepo() throws {
    try worktree("t1", file: "only-here.txt", contents: "task work\n")
    let store = store()
    try finishTask("t1", in: store)

    let verdict = try TaskIntegrationService.verify(taskID: "t1", in: repo,
                                                    command: "test -f only-here.txt",
                                                    store: store, author: "throttle:test")
    XCTAssertTrue(verdict.ok, "the command sees the task's tree, not the base's")
}
```

- [ ] **Step 5: Implémenter `verify`**

Ajouter à `TaskIntegrationService`, sous `// MARK: - Verify`:

```swift
struct Verdict: Sendable, Equatable {
    let ok: Bool
    let output: String
    let stamp: String
}

/// The longest a verification may run before it is killed. A project whose suite
/// takes longer than this should say so in its own command.
static let defaultTimeout: TimeInterval = 900
private static let outputLimit = 4000

/// Runs the project's verification command in the task's worktree and writes the
/// `checked` event for it.
///
/// It runs *after* the rebase, on the combined tree, because a semantic conflict
/// passes the textual merge and only shows up when the two sides are executed
/// together — evidence produced by the agent before the rebase says nothing about
/// what is about to be merged.
///
/// Consent is the caller's to obtain: this function runs what it is given.
@discardableResult
static func verify(taskID: String, in repo: URL, command: String,
                   timeout: TimeInterval = defaultTimeout,
                   store: PlanStore?, author: String) throws -> Verdict {
    let worktree = try existingWorktree(taskID, in: repo)
    let stamp = try assess(taskID: taskID, in: repo).stamp
    let result = shell(command, in: worktree, timeout: timeout)
    let verdict = Verdict(ok: result.ok, output: String(result.output.suffix(outputLimit)),
                          stamp: stamp)

    try store?.append(TaskEvent(seq: 0, timestamp: Date(), author: author, type: .checked,
                                ref: stamp, reason: verdict.ok ? nil : verdict.output,
                                summary: command, ok: verdict.ok),
                      to: taskID)
    return verdict
}

private static func shell(_ command: String, in directory: URL,
                          timeout: TimeInterval) -> (ok: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (false, String(describing: error))
    }

    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    return (process.terminationStatus == 0, String(bytes: data, encoding: .utf8) ?? "")
}
```

Ajouter le paramètre `ok:` à l'appel `TaskEvent(...)` si l'init l'exige positionnellement (il est en dernier, après `missionID`).

- [ ] **Step 6: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/VerifyConsentTests` puis `-only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: PASS (3 + 11).

- [ ] **Step 7: Commit**

```bash
git add Throttle/Services/VerifyConsent.swift Throttle/Services/TaskIntegrationService.swift \
        ThrottleTests/ServiceTests/VerifyConsentTests.swift \
        ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift
git commit -m "[throttle] feat: verify the combined tree, and never run unconsented shell"
```

---

### Task 5: `integrate` — quatre refus, puis un fast-forward

**Files:**
- Modify: `Throttle/Services/TaskIntegrationService.swift`
- Test: `ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift`

**Interfaces:**
- Consumes: `assess`, `verify`, `TaskCheck`, `PlanStore.state(for:)`, `PlanStore.append(_:to:)`.
- Produces: `static func integrate(taskID: String, in repo: URL, store: PlanStore, task: PlanTask, author: String) throws -> String`

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
// MARK: - integrate

func test_integrate_fastForwardsTheBaseAndLogsTheSHA() throws {
    let path = try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)
    try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                      store: store, author: "throttle:test")

    let sha = try TaskIntegrationService.integrate(taskID: "t1", in: repo, store: store,
                                                   task: PlanTask(id: "t1", title: "T1"),
                                                   author: "throttle:test")
    XCTAssertEqual(sha, headSHA(path), "the base is now exactly the task's tip")
    XCTAssertEqual(headSHA(), sha)
    let state = try store.state(for: "t1")
    XCTAssertEqual(state.status, .integrated)
    XCTAssertEqual(state.integratedSHA, sha)
}

func test_integrate_refusesAnUnverifiedTask() throws {
    try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)
    XCTAssertThrowsError(try TaskIntegrationService.integrate(
        taskID: "t1", in: repo, store: store,
        task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
        XCTAssertEqual($0 as? TaskIntegrationError, .refused(.unverified))
    }
    XCTAssertEqual(try store.state(for: "t1").status, .done, "nothing moved")
}

func test_integrate_refusesWhenTheBaseMovedAfterTheCheck() throws {
    try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)
    try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                      store: store, author: "throttle:test")

    try "elsewhere\n".write(to: repo.appendingPathComponent("other.txt"),
                            atomically: true, encoding: .utf8)
    run(["add", "."]); run(["commit", "-q", "-m", "base moves after the check"])
    let baseBefore = headSHA()

    XCTAssertThrowsError(try TaskIntegrationService.integrate(
        taskID: "t1", in: repo, store: store,
        task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
        // Behind the base is the first thing that is wrong, and the stale check
        // the second — either refusal is correct, an integration is not.
        XCTAssertNotNil($0 as? TaskIntegrationError)
    }
    XCTAssertEqual(headSHA(), baseBefore, "the base was not written to")
}

func test_integrate_refusesAGatedTaskWithoutAVerdict() throws {
    try worktree("t1", file: "task.txt", contents: "work\n")
    let store = PlanStore(projectRoot: repo)
    try store.bootstrap(Plan(projectId: "p", title: "P",
                             tasks: [PlanTask(id: "t1", title: "T1", sotaGate: true)]))
    try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .claimed), to: "t1")
    try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "claude:a", type: .completed), to: "t1")

    XCTAssertThrowsError(try TaskIntegrationService.integrate(
        taskID: "t1", in: repo, store: store,
        task: PlanTask(id: "t1", title: "T1", sotaGate: true), author: "throttle:test")) {
        XCTAssertEqual($0 as? TaskIntegrationError, .refused(.ungated))
    }
}

func test_integrate_refusesADirtyWorktree() throws {
    let path = try worktree("t1", file: "task.txt", contents: "work\n")
    let store = store()
    try finishTask("t1", in: store)
    try TaskIntegrationService.verify(taskID: "t1", in: repo, command: "true",
                                      store: store, author: "throttle:test")
    try "scratch\n".write(to: path.appendingPathComponent("notes.txt"),
                          atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try TaskIntegrationService.integrate(
        taskID: "t1", in: repo, store: store,
        task: PlanTask(id: "t1", title: "T1"), author: "throttle:test")) {
        XCTAssertEqual($0 as? TaskIntegrationError, .refused(.dirty))
    }
}
```

- [ ] **Step 2: Lancer pour voir l'échec**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: échec de compilation — `integrate` n'existe pas.

- [ ] **Step 3: Implémenter**

Ajouter à `TaskIntegrationService`, sous `// MARK: - Integrate`:

```swift
/// Fast-forwards the base branch onto a finished task, and writes `integrated`.
///
/// Four refusals, in the order that makes the message useful: a worktree still
/// holding loose work, a task not sitting on the current base, a check that is not
/// green for these exact two SHAs, and a SOTA-gated task counter-analysis has not
/// ruled on.
///
/// The merge itself is `--ff-only` on purpose: after a rebase the task's tip is a
/// descendant of the base, so the merge cannot invent a conflict the shown diff did
/// not contain. A failing fast-forward means one thing — the base moved between the
/// diff and the click — and that is a refusal, not a merge commit.
@discardableResult
static func integrate(taskID: String, in repo: URL, store: PlanStore,
                      task: PlanTask, author: String) throws -> String {
    let assessment = try assess(taskID: taskID, in: repo)
    guard !assessment.isDirty else { throw TaskIntegrationError.refused(.dirty) }
    guard assessment.behindBy == 0 else { throw TaskIntegrationError.refused(.behind) }

    let state = try store.state(for: taskID)
    guard let check = state.lastCheck, check.ok, check.stamp == assessment.stamp else {
        throw TaskIntegrationError.refused(.unverified)
    }
    if task.sotaGate {
        guard state.verdictBy != nil else { throw TaskIntegrationError.refused(.ungated) }
    }

    let branch = try TaskWorktreeService.branchName(for: taskID)
    let merge = git(["merge", "--ff-only", branch], in: repo)
    guard merge.ok else { throw TaskIntegrationError.gitFailed(merge.output) }

    let sha = try self.sha("HEAD", in: repo)
    try store.append(TaskEvent(seq: 0, timestamp: Date(), author: author,
                               type: .integrated, ref: sha), to: taskID)
    return sha
}
```

- [ ] **Step 4: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/TaskIntegrationServiceTests`
Expected: PASS (16 tests).

- [ ] **Step 5: Lancer la suite entière pour vérifier qu'on n'a rien cassé**

Run: `xcodebuild test … -only-testing:ThrottleTests`
Expected: seuls les deux `WindowCalculatorTests.test_weeklySonnet_*` échouent (échecs pré-existants, cf. Global Constraints).

- [ ] **Step 6: Commit**

```bash
git add Throttle/Services/TaskIntegrationService.swift \
        ThrottleTests/ServiceTests/TaskIntegrationServiceTests.swift
git commit -m "[throttle] feat: integrate on a click, refuse four ways"
```

---

### Task 6: La carte d'intégration dans le Cockpit

**Files:**
- Create: `Throttle/UI/Cockpit/PlanIntegrationView.swift`
- Modify: `Throttle/State/PlanModel.swift`
- Modify: `Throttle/UI/Cockpit/PlanTreeView.swift:159-201` (l'inspecteur)
- Test: `ThrottleTests/ServiceTests/PlanIntegrationFlowTests.swift`

**Interfaces:**
- Consumes: `TaskIntegrationService.{assess, rebase, verify, integrate, diff}`, `VerifyConsent`, `PlanModel.{plan, store, root, state(_:)}`.
- Produces:
  ```swift
  extension PlanModel {
      enum IntegrationStep: String, Sendable { case idle, rebasing, verifying, merging }
      func verifyCommand(for taskID: String) -> String?
      func assessment(for taskID: String) -> Assessment?
      func integrate(taskID: String) -> String?     // nil on success, else the refusal text
  }
  extension PlanTreeView { @ViewBuilder func integration(_ task: PlanTask, _ state: TaskState) -> some View }
  ```

- [ ] **Step 1: Écrire le test du chaînage (sans UI)**

Créer `ThrottleTests/ServiceTests/PlanIntegrationFlowTests.swift`. Ce test couvre ce que le bouton fait, sans passer par SwiftUI — c'est l'enchaînement qui a de la valeur, pas le rendu.

```swift
@testable import Throttle
import XCTest

/// What the single "Integrate" button does, tested where it can be: the sequence
/// rebase → verify → merge, and the fact that it stops at the first refusal.
/// `PlanModel` is `@MainActor`, so this suite is too.
@MainActor
final class PlanIntegrationFlowTests: XCTestCase {

    private var repo = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        run(["init", "-q", "-b", "main"])
        run(["config", "user.email", "test@example.com"])
        run(["config", "user.name", "Test"])
        try "seed\n".write(to: repo.appendingPathComponent("file.txt"),
                           atomically: true, encoding: .utf8)
        run(["add", "."]); run(["commit", "-q", "-m", "seed"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
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

    private func model(verify: String?) throws -> PlanModel {
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
        model.bind(to: repo)
        return model
    }

    func test_theTaskVerifyCommandOverridesTheProjectOne() throws {
        let store = PlanStore(projectRoot: repo)
        try store.bootstrap(Plan(projectId: "p", title: "P", verify: "project-level",
                                 tasks: [PlanTask(id: "t1", title: "T1", verify: "task-level")]))
        let model = PlanModel()
        model.bind(to: repo)
        XCTAssertEqual(model.verifyCommand(for: "t1"), "task-level")
    }

    func test_integrateRefusesWithoutAVerifyCommand() throws {
        let model = try model(verify: nil)
        let refusal = model.integrate(taskID: "t1")
        XCTAssertNotNil(refusal)
        XCTAssertEqual(model.state("t1").status, .done, "nothing moved")
    }

    func test_integrateRunsTheWholeSequenceOnce() throws {
        let model = try model(verify: "true")
        VerifyConsent.grant(project: repo, command: "true")
        XCTAssertNil(model.integrate(taskID: "t1"))
        XCTAssertEqual(model.state("t1").status, .integrated)
    }

    func test_integrateStopsAtAFailingVerification() throws {
        let model = try model(verify: "exit 1")
        VerifyConsent.grant(project: repo, command: "exit 1")
        XCTAssertNotNil(model.integrate(taskID: "t1"))
        XCTAssertEqual(model.state("t1").status, .done, "a red check never merges")
        XCTAssertEqual(model.state("t1").lastCheck?.ok, false)
    }
}
```

`PlanModel.bind(to:)` est la méthode existante qui pointe le modèle sur un projet (`PlanModel.swift:47`); elle est idempotente, donc l'appeler dans un test est sans effet de bord.

- [ ] **Step 2: Lancer pour voir l'échec**

Run: `xcodebuild test … -only-testing:ThrottleTests/PlanIntegrationFlowTests`
Expected: échec de compilation — `verifyCommand`, `integrate` n'existent pas sur `PlanModel`.

- [ ] **Step 3: Câbler `PlanModel`**

Ajouter **dans le corps de la classe** `PlanModel` (pas dans une extension d'un autre fichier: `root` et `store` sont `private`):

```swift
// MARK: - Integration

/// What the button is doing right now, so the card can say which step it stopped at.
enum IntegrationStep: String, Sendable {
    case idle, rebasing, verifying, merging
}

/// The task's own command wins over the project's: a task that needs a narrower
/// check should not be forced through the whole suite.
func verifyCommand(for taskID: String) -> String? {
    plan?.task(taskID)?.verify ?? plan?.verify
}

func assessment(for taskID: String) -> Assessment? {
    guard let root else { return nil }
    return try? TaskIntegrationService.assess(taskID: taskID, in: root)
}

func integrationDiff(for taskID: String) -> String {
    guard let root else { return "" }
    return (try? TaskIntegrationService.diff(taskID: taskID, in: root)) ?? ""
}

/// Runs rebase → verify → merge and returns nil on success, or the refusal to
/// show. Stops at the first thing that says no; nothing is written to the base
/// branch unless all three passed.
func integrate(taskID: String) -> String? {
    guard let root, let store, let task = plan?.task(taskID) else {
        return "This project has no plan to integrate against."
    }
    guard let command = verifyCommand(for: taskID) else {
        return "No verify command in this plan — add `verify` to the plan or the task."
    }
    guard VerifyConsent.isGranted(project: root, command: command) else {
        pendingVerifyCommand = command
        return "Throttle has not been allowed to run `\(command)` in this project yet."
    }

    integrationStep = .rebasing
    defer { integrationStep = .idle; reload() }
    do {
        try TaskIntegrationService.rebase(taskID: taskID, in: root)
        integrationStep = .verifying
        let verdict = try TaskIntegrationService.verify(taskID: taskID, in: root,
                                                        command: command, store: store,
                                                        author: Self.author)
        guard verdict.ok else {
            return "The verification failed, so nothing was merged.\n"
                + String(verdict.output.suffix(600))
        }
        integrationStep = .merging
        _ = try TaskIntegrationService.integrate(taskID: taskID, in: root, store: store,
                                                 task: task, author: Self.author)
        return nil
    } catch let error as TaskIntegrationError {
        return Self.explain(error)
    } catch {
        return String(describing: error)
    }
}

func allowVerifyCommand() {
    guard let root, let command = pendingVerifyCommand else { return }
    VerifyConsent.grant(project: root, command: command)
    pendingVerifyCommand = nil
}

private static let author = "throttle:app"

private static func explain(_ error: TaskIntegrationError) -> String {
    switch error {
    case .noWorktree(let id):    return "\(id) has no worktree — nothing to integrate."
    case .gitFailed(let output): return String(output.suffix(600))
    case .refused(.dirty):       return "The worktree still holds uncommitted changes."
    case .refused(.behind):      return "The base moved — rebase again before integrating."
    case .refused(.unverified):  return "No green check for these exact commits."
    case .refused(.ungated):     return "SOTA-gated: counter-analysis has not ruled on it."
    }
}
```

Ajouter aussi les deux propriétés observables, à côté de `advice` (même style `@Observable`/`var` que le reste du modèle):

```swift
var integrationStep: IntegrationStep = .idle
/// The command the user has been asked to allow, if any.
var pendingVerifyCommand: String?
```

- [ ] **Step 4: Lancer les tests**

Run: `xcodebuild test … -only-testing:ThrottleTests/PlanIntegrationFlowTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Écrire la carte**

Créer `Throttle/UI/Cockpit/PlanIntegrationView.swift`:

```swift
import SwiftUI

// The block that writes to the base branch, kept out of the tree view for the same
// reason as the recommendation: the part that changes the repository reads on its
// own.
extension PlanTreeView {

    @ViewBuilder
    func integration(_ task: PlanTask, _ state: TaskState) -> some View {
        if state.status == .integrated {
            VStack(alignment: .leading, spacing: 4) {
                section("INTEGRATED")
                Text(state.integratedSHA.map { String($0.prefix(10)) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else if state.status == .done, let assessment = model.assessment(for: task.id) {
            VStack(alignment: .leading, spacing: 6) {
                section("INTEGRATION")

                Text("\(assessment.files.count) file(s)  "
                     + "+\(assessment.files.reduce(0) { $0 + $1.added })  "
                     + "−\(assessment.files.reduce(0) { $0 + $1.removed })")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                switch assessment.mergeability {
                case .clean:
                    if assessment.behindBy > 0 {
                        Text("\(assessment.behindBy) commit(s) behind — will rebase first")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .conflicted(let paths):
                    // A quarter of agent branches land here, so it is a state with
                    // named files, not an error to apologise for.
                    Text("Conflicts with the base in:")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    ForEach(paths, id: \.self) { path in
                        Text("· \(path)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                case .unknown:
                    Text("This git cannot say whether it merges cleanly (needs 2.38).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                if let command = model.verifyCommand(for: task.id) {
                    Text("verify: \(command)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button(model.integrationStep == .idle
                           ? "Integrate" : model.integrationStep.rawValue.capitalized) {
                        integrationError = model.integrate(taskID: task.id)
                    }
                    .controlSize(.small)
                    .disabled(model.integrationStep != .idle || blocked(assessment))

                    if model.pendingVerifyCommand != nil {
                        Button("Allow this command") { model.allowVerifyCommand() }
                            .controlSize(.small)
                    }
                }

                if let integrationError {
                    Text(integrationError).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Diff") {
                    ScrollView(.horizontal) {
                        Text(model.integrationDiff(for: task.id))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                }
                .font(.system(size: 11))
            }
        }
    }
}
```

Dans `PlanTreeView`, ajouter l'état `@State var integrationError: String?` à côté de `launchError`, et appeler la carte dans l'inspecteur, juste après le bloc `recommendation`:

```swift
if let advice = model.advice[id] { recommendation(advice, taskID: id) }

integration(task, state)
```

Et, dans la même extension, le prédicat que le bouton lit — `Mergeability` porte une valeur associée, donc il se teste avec `if case`, jamais avec `==`:

```swift
/// Conflicts and loose changes are the two things no click can push through.
func blocked(_ assessment: Assessment) -> Bool {
    if case .conflicted = assessment.mergeability { return true }
    return assessment.isDirty
}
```

- [ ] **Step 6: Compiler et relancer la suite entière**

Run: `xcodebuild test … -only-testing:ThrottleTests`
Expected: seuls les deux `WindowCalculatorTests.test_weeklySonnet_*` échouent.

- [ ] **Step 7: Commit**

```bash
git add Throttle/UI/Cockpit/PlanIntegrationView.swift Throttle/UI/Cockpit/PlanTreeView.swift \
        Throttle/State/PlanModel.swift ThrottleTests/ServiceTests/PlanIntegrationFlowTests.swift
git commit -m "[throttle] feat: one button, three steps, and it says where it stopped"
```

---

## Ce que ce plan laisse volontairement de côté

- La résolution de conflit: la carte les nomme, personne ne les résout à ta place.
- Le nettoyage du worktree après intégration: `TaskWorktreeService.remove` existe déjà et refuse tant qu'il reste du travail non intégré; après un fast-forward il n'en reste plus, donc rien à écrire.
- Le best-of-N et la boucle « jusqu'au SOTA »: lot E restant.
- Le push et les PR: hors périmètre de la spec.
