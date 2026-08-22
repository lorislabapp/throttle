import Foundation

/// Scans `~/GitHub` for what the portfolio REBUILDS instead of sharing — the native
/// port of the `lls-map` tool, so the map lives in the cockpit and refreshes on demand:
///   • code     — Swift component filenames appearing in ≥2 app repos
///   • research — deep-research / docs topics (filename bigrams) recurring across ≥2 repos
///
/// Pure filesystem read, no dependencies. Runs off the main actor (walking ~/GitHub is
/// I/O-heavy) and returns a `Sendable` graph the SwiftUI view renders.
struct PortfolioNode: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable { case app, code, research }
    let id: String
    let label: String
    let kind: Kind
    let reach: Int          // code/research: # apps that share it; app: # research docs
}

struct PortfolioEdge: Sendable, Hashable { let from: String; let to: String }

struct PortfolioGraph: Sendable {
    var nodes: [PortfolioNode] = []
    var edges: [PortfolioEdge] = []
    var appCount = 0, codeCount = 0, researchCount = 0, docCount = 0
}

enum PortfolioMapService {
    private static let componentRE = try! NSRegularExpression(
        pattern: #"(View|Service|Manager|Store|Provider|Kit|Helper|Client|Engine|Card|State|Theme|Paywall|Onboarding)\.swift$"#)
    private static let skipDirs: Set<String> = [".git", "node_modules", ".build", "Pods",
                                                "DerivedData", ".worktrees", "build", ".swiftpm"]

    /// Shares `RepoIndexer`'s virtualenv rule rather than keeping a second list.
    /// Impact here is small (this walker only reads `*.swift`), but two
    /// divergent exclusion lists is how the semantic index came to embed 1.8 GB
    /// of torch and scipy.
    private static func shouldSkip(_ name: String) -> Bool {
        skipDirs.contains(name) || RepoIndexer.isExcluded(directoryNamed: name)
    }
    private static let stop: Set<String> = [
        "the", "and", "for", "with", "from", "into", "claude", "code", "app", "apps", "ios", "macos", "mac",
        "swift", "research", "deep", "readme", "index", "notes", "note", "doc", "docs", "plan", "plans",
        "final", "draft", "brief", "report", "analysis", "strategy", "phase", "phase1", "phase2", "phase3",
        "implementation", "architecture", "foundation", "overview", "design", "guide", "part", "section",
        "spec", "specs", "agenda", "queue", "synthese", "synthesis", "audit", "roadmap", "tasks", "task",
        "todo", "status", "summary", "current", "new", "old", "test", "tests", "fix", "fixes", "update",
        "flow", "product", "gemini"]

    static func scan(minApps: Int = 2, topCode: Int = 14, topResearch: Int = 16) async -> PortfolioGraph {
        await Task.detached(priority: .utility) { computeSync(minApps, topCode, topResearch) }.value
    }

    private static func computeSync(_ minApps: Int, _ topCode: Int, _ topResearch: Int) -> PortfolioGraph {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("GitHub", isDirectory: true)
        guard let repos = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return PortfolioGraph() }

        var codeToRepos: [String: Set<String>] = [:]
        var researchToRepos: [String: Set<String>] = [:]
        var swiftCount: [String: Int] = [:]
        var researchDocs: [String: Int] = [:]

        for repoURL in repos where (try? repoURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let repo = repoURL.lastPathComponent
            if repo.hasPrefix(".") { continue }
            guard let en = fm.enumerator(at: repoURL, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if shouldSkip(url.lastPathComponent),
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    en.skipDescendants(); continue
                }
                let name = url.lastPathComponent
                let low = url.path.lowercased()
                if name.hasSuffix(".swift") {
                    swiftCount[repo, default: 0] += 1
                    let r = NSRange(name.startIndex..., in: name)
                    if componentRE.firstMatch(in: name, range: r) != nil {
                        codeToRepos[name, default: []].insert(repo)
                    }
                } else if name.hasSuffix(".md"), low.contains("research") || low.contains("/docs/") {
                    researchDocs[repo, default: 0] += 1
                    for topic in bigrams(name) { researchToRepos[topic, default: []].insert(repo) }
                }
            }
        }

        let apps = Set(swiftCount.filter { $0.value >= 20 }.keys)
        let sharedCode = codeToRepos.mapValues { $0.intersection(apps) }
            .filter { $0.value.count >= minApps }
        let sharedResearch = researchToRepos.filter { $0.value.count >= minApps && $0.value.count <= max(3, apps.count / 2) }

        var g = PortfolioGraph()
        g.appCount = apps.count
        g.codeCount = sharedCode.count
        g.researchCount = sharedResearch.count
        g.docCount = researchDocs.values.reduce(0, +)

        var appSet: Set<String> = []
        for (comp, rs) in sharedCode.sorted(by: { $0.value.count > $1.value.count }).prefix(topCode) {
            let id = "code:" + comp
            g.nodes.append(.init(id: id, label: String(comp.dropLast(6)), kind: .code, reach: rs.count))
            for r in rs { appSet.insert(r); g.edges.append(.init(from: id, to: "app:" + r)) }
        }
        for (topic, rs) in sharedResearch.sorted(by: { $0.value.count > $1.value.count }).prefix(topResearch) {
            let id = "res:" + topic
            g.nodes.append(.init(id: id, label: topic, kind: .research, reach: rs.count))
            for r in rs { appSet.insert(r); g.edges.append(.init(from: id, to: "app:" + r)) }
        }
        for a in appSet.sorted() {
            g.nodes.append(.init(id: "app:" + a, label: a, kind: .app, reach: researchDocs[a] ?? 0))
        }
        return g
    }

    /// Distinctive research topics = bigrams of significant filename tokens. Single
    /// tokens ("architecture", "implementation") are too generic; adjacent pairs
    /// ("apple-foundation", "quic-nat") mean the same subject was researched twice.
    private static func bigrams(_ filename: String) -> Set<String> {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let toks = stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) && Int($0) == nil }
        guard toks.count >= 2 else { return [] }
        var out: Set<String> = []
        for i in 0..<(toks.count - 1) { out.insert("\(toks[i])-\(toks[i+1])") }
        return out
    }
}
