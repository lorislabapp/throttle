import Foundation

/// DeltaMem (Chantier 2) — a residual-tree long-term memory graph. A general fact
/// is a ROOT node; project- or context-specific variations are DELTAS that hang
/// off a root and store ONLY the residual (the addition/override), never a full
/// copy of the root. `resolve` composes a root with the deltas applicable to a
/// given scope into one effective fact. 100% local, JSON-backed, no external deps.
///
/// Example: root "How the Stripe API works" + delta(scope: "Throttle",
/// "pin apiVersion 2024-11-20.acacia") → resolving for Throttle yields the general
/// fact plus that one project-specific caveat, without duplicating the root.
struct DeltaMemNode: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var title: String
    var body: String
    var createdAt: Date
}

struct DeltaMemDelta: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var rootId: String
    var scope: String        // project label / path the variation applies to
    var body: String         // the residual only
    var createdAt: Date
}

struct DeltaMemGraph: Codable, Sendable, Equatable {
    var roots: [DeltaMemNode] = []
    var deltas: [DeltaMemDelta] = []
}

enum DeltaMemStore {

    /// Override-able for tests; defaults to the app-support store.
    nonisolated(unsafe) static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Throttle/deltamem", isDirectory: true)

    private static var file: URL { baseDir.appendingPathComponent("graph.json") }

    // MARK: - Persistence

    static func load() -> DeltaMemGraph {
        guard let data = try? Data(contentsOf: file),
              let g = try? JSONDecoder.iso.decode(DeltaMemGraph.self, from: data) else { return DeltaMemGraph() }
        return g
    }

    static func save(_ g: DeltaMemGraph) {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(g) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Mutations

    @discardableResult
    static func addRoot(title: String, body: String, id: String = UUID().uuidString, now: Date = Date()) -> DeltaMemNode {
        var g = load()
        let node = DeltaMemNode(id: id, title: title, body: body, createdAt: now)
        g.roots.append(node)
        save(g)
        return node
    }

    /// Add a residual delta onto an existing root. Returns nil if the root is
    /// unknown (never orphan a delta).
    @discardableResult
    static func addDelta(rootId: String, scope: String, body: String,
                         id: String = UUID().uuidString, now: Date = Date()) -> DeltaMemDelta? {
        var g = load()
        guard g.roots.contains(where: { $0.id == rootId }) else { return nil }
        let d = DeltaMemDelta(id: id, rootId: rootId, scope: scope, body: body, createdAt: now)
        g.deltas.append(d)
        save(g)
        return d
    }

    /// Promote a validated OKF research bundle into a DeltaMem ROOT, so it becomes
    /// a recallable long-term fact (throttle_recall surfaces both stores, but as a
    /// root it can additionally carry project-specific deltas). Sources are appended
    /// to the body for provenance.
    @discardableResult
    static func importOKF(_ bundle: OKFBundle, now: Date = Date()) -> DeltaMemNode {
        var body = bundle.body
        if !bundle.sources.isEmpty {
            body += "\n\nSources:\n" + bundle.sources.map { "- \($0)" }.joined(separator: "\n")
        }
        return addRoot(title: bundle.title, body: body, now: now)
    }

    // MARK: - Queries

    static func roots() -> [DeltaMemNode] { load().roots }

    static func deltas(forRoot id: String) -> [DeltaMemDelta] {
        load().deltas.filter { $0.rootId == id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// First root whose title contains `topic` (case-insensitive).
    static func findRoot(matching topic: String) -> DeltaMemNode? {
        load().roots.first { $0.title.localizedCaseInsensitiveContains(topic) }
    }

    /// Compose a root's body with every delta applicable to `scope` into one
    /// effective fact. A delta applies when its scope is empty (global) or the
    /// query scope matches it (either direction substring). nil if root unknown.
    static func resolve(rootId: String, scope: String) -> String? {
        let g = load()
        guard let root = g.roots.first(where: { $0.id == rootId }) else { return nil }
        let applicable = g.deltas
            .filter { $0.rootId == rootId && scopeApplies(delta: $0.scope, query: scope) }
            .sorted { $0.createdAt < $1.createdAt }
        var out = root.body
        for d in applicable {
            let tag = d.scope.isEmpty ? "global" : d.scope
            out += "\n\n— [\(tag)] \(d.body)"
        }
        return out
    }

    static func scopeApplies(delta: String, query: String) -> Bool {
        if delta.isEmpty { return true }
        if query.isEmpty { return false }
        return query.localizedCaseInsensitiveContains(delta) || delta.localizedCaseInsensitiveContains(query)
    }
}

// Shared ISO8601 JSON coders (date round-trips as an ISO string, human-diffable).
extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
