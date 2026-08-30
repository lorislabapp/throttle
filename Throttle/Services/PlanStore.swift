import CryptoKit
import Foundation

enum PlanStoreError: Error, Equatable {
    case unsafeTaskID(String)
    case unknownTask(String)
    case missingPlan(String)
    case planAlreadyExists(String)
}

/// Reads and writes a project's `.throttle/` directory.
///
/// An actor because it is the single writer: agents reach the log through
/// `ThrottleMCPServer`, which lives in this same process, so appends serialise
/// here and the `prev` hash chain stays intact without a lock file. A log written
/// by something that bypassed Throttle still parses — the chain simply reports
/// itself broken, which is information rather than damage.
///
/// What the chain is worth, precisely: it catches an edit to any line that has a
/// successor. It does NOT catch an edit to the final line, which nothing vouches
/// for, and it does not survive a writer that rebuilds every hash. It is
/// tamper-evidence against careless edits, not proof of authorship — that would
/// need a signature and a key, which lot E can decide it wants.
final class PlanStore: @unchecked Sendable {

    private let root: URL
    private let files = FileManager.default

    /// Not an actor: `ThrottleMCPServer` is a synchronous stdin loop, and bridging
    /// it to an actor would mean blocking a thread on every tool call. A plain lock
    /// gives the same single-writer guarantee without that seam.
    ///
    /// NSLock is not reentrant, so every public method takes the lock exactly once
    /// and delegates to an unlocked `impl`; no public method calls another.
    private let lock = NSLock()

    /// Replaying a log on every filesystem event would re-read every line on every
    /// keystroke of an agent, so replays are memoised on the log's identity.
    private struct CacheKey: Equatable { let size: Int; let mtime: Date }
    private struct Replay { let key: CacheKey; let events: [TaskEvent]; let chainValid: Bool }
    private var replayCache: [String: Replay] = [:]

    init(projectRoot: URL) {
        self.root = projectRoot
    }

    // MARK: - Layout

    private var throttleDir: URL { root.appendingPathComponent(".throttle", isDirectory: true) }
    private var planURL: URL { throttleDir.appendingPathComponent("plan.json") }
    private var logDir: URL { throttleDir.appendingPathComponent("log", isDirectory: true) }
    private var stateDir: URL { throttleDir.appendingPathComponent("state", isDirectory: true) }

    /// Task ids become filenames, so anything that could walk out of `.throttle/`
    /// is refused before it reaches the filesystem.
    private func validated(_ taskID: String) throws -> String {
        let isSafe = !taskID.isEmpty && taskID.count <= 128
            && !taskID.contains("/") && !taskID.contains("\\")
            && !taskID.contains("..") && !taskID.hasPrefix(".")
        guard isSafe else { throw PlanStoreError.unsafeTaskID(taskID) }
        return taskID
    }

    private func logURL(_ taskID: String) throws -> URL {
        logDir.appendingPathComponent("\(try validated(taskID)).ndjson")
    }

    private func stateURL(_ taskID: String) throws -> URL {
        stateDir.appendingPathComponent("\(try validated(taskID)).json")
    }

    // MARK: - Codec

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys keep a line's bytes stable, which is what makes the hash
        // chain reproducible across machines and Swift versions.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func hash(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Plan

    func loadPlan() throws -> Plan {
        lock.lock(); defer { lock.unlock() }
        return try loadPlanImpl()
    }

    private func loadPlanImpl() throws -> Plan {
        guard let data = files.contents(atPath: planURL.path) else {
            throw PlanStoreError.missingPlan(planURL.path)
        }
        return try Self.decoder.decode(Plan.self, from: data)
    }

    /// Writes a starting plan, and refuses if one already exists. Bootstrapping
    /// over a live plan would discard tasks agents are holding.
    func bootstrap(_ plan: Plan) throws {
        lock.lock(); defer { lock.unlock() }
        guard !files.fileExists(atPath: planURL.path) else {
            throw PlanStoreError.planAlreadyExists(planURL.path)
        }
        try files.createDirectory(at: throttleDir, withIntermediateDirectories: true)
        try Self.encoder.encode(plan).write(to: planURL, options: .atomic)
    }

    func planExists() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files.fileExists(atPath: planURL.path)
    }

    // MARK: - Log

    /// Parses a task's log and verifies its chain in one pass. A line that fails to
    /// decode is skipped and marks the chain broken rather than aborting the read —
    /// a partially corrupt log should still show the user what it does contain.
    func events(for taskID: String) throws -> (events: [TaskEvent], chainValid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return try eventsImpl(for: taskID)
    }

    private func eventsImpl(for taskID: String) throws -> (events: [TaskEvent], chainValid: Bool) {
        let url = try logURL(taskID)
        guard let attrs = try? files.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date else {
            return ([], true)
        }
        let key = CacheKey(size: size, mtime: mtime)
        if let cached = replayCache[taskID], cached.key == key {
            return (cached.events, cached.chainValid)
        }

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var events: [TaskEvent] = []
        var chainValid = true
        var expectedPrev: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            guard let event = try? Self.decoder.decode(TaskEvent.self, from: Data(raw.utf8)) else {
                chainValid = false
                continue
            }
            if event.prev != expectedPrev { chainValid = false }
            expectedPrev = Self.hash(raw)
            events.append(event)
        }

        replayCache[taskID] = Replay(key: key, events: events, chainValid: chainValid)
        return (events, chainValid)
    }

    /// Appends one event, filling in `seq` and `prev` from the log's current tail.
    /// The caller supplies intent; the store owns the chain.
    @discardableResult
    func append(_ event: TaskEvent, to taskID: String) throws -> TaskEvent {
        lock.lock(); defer { lock.unlock() }
        return try appendImpl(event, to: taskID)
    }

    private func appendImpl(_ event: TaskEvent, to taskID: String) throws -> TaskEvent {
        let url = try logURL(taskID)
        try files.createDirectory(at: logDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: true)

        var stamped = event
        stamped.seq = lines.count + 1
        stamped.prev = lines.last.map { Self.hash(String($0)) }

        let data = try Self.encoder.encode(stamped)
        guard var line = String(data: data, encoding: .utf8) else { return stamped }
        line += "\n"

        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: url, options: .atomic)
        }

        replayCache[taskID] = nil
        return stamped
    }

    // MARK: - Projection

    func state(for taskID: String) throws -> TaskState {
        lock.lock(); defer { lock.unlock() }
        let plan = try loadPlanImpl()
        guard let task = plan.task(taskID) else { throw PlanStoreError.unknownTask(taskID) }
        let (events, chainValid) = try eventsImpl(for: taskID)
        return PlanProjection.project(task: task, events: events, chainValid: chainValid)
    }

    /// The whole tree, ready for the UI and the dispatcher. Writes the derived
    /// state files as a side effect — they are a cache for other readers, never a
    /// source of truth, and `resolveAll` never reads them back.
    func resolveAll() throws -> (plan: Plan, states: [String: TaskState]) {
        lock.lock(); defer { lock.unlock() }
        let plan = try loadPlanImpl()
        var leafStates: [String: TaskState] = [:]
        for task in plan.tasks {
            let (events, chainValid) = try eventsImpl(for: task.id)
            guard !events.isEmpty else { continue }
            leafStates[task.id] = PlanProjection.project(task: task, events: events,
                                                         chainValid: chainValid)
        }
        let states = PlanProjection.resolve(plan: plan, leafStates: leafStates)
        try? writeStateCache(states)
        return (plan, states)
    }

    private func writeStateCache(_ states: [String: TaskState]) throws {
        try files.createDirectory(at: stateDir, withIntermediateDirectories: true)
        for (id, state) in states {
            guard let url = try? stateURL(id), let data = try? Self.encoder.encode(state) else { continue }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Throws away every derived file. The next `resolveAll` must reproduce them
    /// exactly — that is the property that proves the log is really the truth.
    func discardStateCache() throws {
        lock.lock(); defer { lock.unlock() }
        replayCache.removeAll()
        try? files.removeItem(at: stateDir)
    }
}
