import Foundation

/// Provider-neutral, local portfolio retrieval. The engine contains no user or
/// project names: every installation discovers its own repositories and may
/// layer a portable JSON/YAML profile on top after installation.
struct GlobalRAGProfile: Codable, Equatable, Sendable {
    struct Project: Codable, Equatable, Sendable {
        var match: String
        var displayName: String?
        var aliases: [String] = []
        var capabilities: [String] = []
        var tools: [String] = []
        var workflows: [String] = []
        var handoffs: [String] = []

        enum CodingKeys: String, CodingKey {
            case match
            case displayName = "display_name"
            case aliases, capabilities, tools, workflows, handoffs
        }
    }

    var version: Int = 1
    var roots: [String] = []
    var exclusions: [String] = []
    var projects: [Project] = []
    var maxResults: Int = 6

    enum CodingKeys: String, CodingKey {
        case version, roots, exclusions, projects
        case maxResults = "max_results"
    }

    static let empty = GlobalRAGProfile()
}

struct GlobalRAGRecord: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case project, capability, tool, workflow, handoff, research, memory
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let project: String
    let projectPath: String?
    let evidencePath: String?
    let modifiedAt: Date?
    let configured: Bool
}

struct GlobalRAGSnapshot: Codable, Equatable, Sendable {
    let builtAt: Date
    let roots: [String]
    let projectCount: Int
    let records: [GlobalRAGRecord]
}

enum GlobalRAGService {
    enum ProfileFormat { case json, yaml }

    enum ProfileError: LocalizedError, Equatable {
        case unsupportedFormat
        case invalidProfile(String)
        case sensitiveField(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "The profile must be JSON, YAML or YML."
            case .invalidProfile(let reason):
                return "Invalid global RAG profile: \(reason)"
            case .sensitiveField(let key):
                return "Profiles must not contain secrets or credentials (refused field: \(key))."
            }
        }
    }

    static let profileVersion = 1
    static let automaticContextLimit = 6
    static let snapshotMaxAge: TimeInterval = 24 * 60 * 60
    static let rootsDefaultsKey = "throttleGlobalRAGRoots"
    static let exclusionsDefaultsKey = "throttleGlobalRAGExclusions"

    nonisolated(unsafe) static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Throttle/GlobalRAG", isDirectory: true)

    private static var profileURL: URL { baseDir.appendingPathComponent("profile.json") }
    private static var snapshotURL: URL { baseDir.appendingPathComponent("snapshot.json") }
    private static let maxProjects = 500
    private static let maxRecords = 12_000
    private static let maxScannedEntriesPerProject = 3_000
    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".gradle", ".cache", ".idea", ".vscode",
        "node_modules", "Pods", "Carthage", "DerivedData", "build", "dist", "out",
        "target", "vendor", ".venv", "venv", "coverage", "site-packages"
    ]
    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py",
        "kt", "java", "js", "jsx", "ts", "tsx", "cs", "dart"
    ]
    private static let workflowTerms = [
        "build", "test", "verify", "release", "publish", "deploy", "upload",
        "archive", "notar", "submit", "store", "site", "ship", "package"
    ]
    private static let sensitiveTerms = [
        "secret", "password", "passwd", "token", "api_key", "apikey", "private_key",
        "credential", "session_cookie", "auth_key"
    ]

    // MARK: - Profile portability

    static func loadProfile() -> GlobalRAGProfile {
        guard let data = try? Data(contentsOf: profileURL),
              let decoded = try? JSONDecoder().decode(GlobalRAGProfile.self, from: data),
              (try? validate(decoded)) != nil else { return .empty }
        return decoded
    }

    @discardableResult
    static func importProfile(from url: URL) throws -> GlobalRAGProfile {
        let ext = url.pathExtension.lowercased()
        guard ["json", "yaml", "yml"].contains(ext) else { throw ProfileError.unsupportedFormat }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1024 * 1024 else {
            throw ProfileError.invalidProfile("file exceeds 2 MB")
        }
        let profile: GlobalRAGProfile
        if ext == "json" {
            let object = try JSONSerialization.jsonObject(with: data)
            try rejectSensitiveKeys(in: object)
            profile = try JSONDecoder().decode(GlobalRAGProfile.self, from: data)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            try rejectSensitiveYAMLKeys(in: text)
            profile = try parseYAML(text)
        }
        try validate(profile)
        try persist(profile)
        try? FileManager.default.removeItem(at: snapshotURL)
        return profile
    }

    static func exportProfile(to url: URL, format: ProfileFormat) throws {
        let profile = loadProfile()
        try validate(profile)
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(profile)
        case .yaml:
            data = Data(renderYAML(profile).utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    static func saveProfile(_ profile: GlobalRAGProfile) throws {
        try validate(profile)
        try persist(profile)
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private static func persist(_ profile: GlobalRAGProfile) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profile).write(to: profileURL, options: .atomic)
    }

    static func validate(_ profile: GlobalRAGProfile) throws {
        guard profile.version == profileVersion else {
            throw ProfileError.invalidProfile("unsupported version \(profile.version); expected \(profileVersion)")
        }
        guard profile.roots.count <= 32 else { throw ProfileError.invalidProfile("too many roots") }
        guard profile.exclusions.count <= 128 else { throw ProfileError.invalidProfile("too many exclusions") }
        guard profile.projects.count <= maxProjects else { throw ProfileError.invalidProfile("too many project overrides") }
        guard (1...50).contains(profile.maxResults) else {
            throw ProfileError.invalidProfile("max_results must be between 1 and 50")
        }
        for root in profile.roots {
            try validateScalar(root, label: "root")
            let expanded = NSString(string: root).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ProfileError.invalidProfile("roots must be absolute paths") }
        }
        for exclusion in profile.exclusions { try validateScalar(exclusion, label: "exclusion") }
        for project in profile.projects {
            try validateScalar(project.match, label: "project.match")
            guard !project.match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileError.invalidProfile("project.match cannot be empty")
            }
            if let name = project.displayName { try validateScalar(name, label: "project.display_name") }
            for values in [project.aliases, project.capabilities, project.tools, project.workflows, project.handoffs] {
                guard values.count <= 64 else { throw ProfileError.invalidProfile("a project list exceeds 64 entries") }
                for value in values { try validateScalar(value, label: "project value") }
            }
        }
    }

    private static func validateScalar(_ value: String, label: String) throws {
        guard value.count <= 2_000 else { throw ProfileError.invalidProfile("\(label) is too long") }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) else {
            throw ProfileError.invalidProfile("\(label) contains control characters")
        }
    }

    // YAML 1.2 flow arrays/scalars keep the portable format readable while the
    // parser remains deliberately narrow and auditable (not a general YAML VM).
    static func renderYAML(_ profile: GlobalRAGProfile) -> String {
        var lines = [
            "version: \(profile.version)",
            "roots: \(jsonArray(profile.roots))",
            "exclusions: \(jsonArray(profile.exclusions))",
            "max_results: \(profile.maxResults)",
            "projects:"
        ]
        for project in profile.projects {
            lines.append("  - match: \(jsonScalar(project.match))")
            lines.append("    display_name: \(project.displayName.map(jsonScalar) ?? "null")")
            lines.append("    aliases: \(jsonArray(project.aliases))")
            lines.append("    capabilities: \(jsonArray(project.capabilities))")
            lines.append("    tools: \(jsonArray(project.tools))")
            lines.append("    workflows: \(jsonArray(project.workflows))")
            lines.append("    handoffs: \(jsonArray(project.handoffs))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parseYAML(_ text: String) throws -> GlobalRAGProfile {
        var profile = GlobalRAGProfile.empty
        var projects: [GlobalRAGProfile.Project] = []
        var current: GlobalRAGProfile.Project?
        var inProjects = false

        func assign(_ key: String, _ raw: String, to project: inout GlobalRAGProfile.Project) throws {
            switch key {
            case "match": project.match = try parseString(raw)
            case "display_name": project.displayName = try parseOptionalString(raw)
            case "aliases": project.aliases = try parseStringArray(raw)
            case "capabilities": project.capabilities = try parseStringArray(raw)
            case "tools": project.tools = try parseStringArray(raw)
            case "workflows": project.workflows = try parseStringArray(raw)
            case "handoffs": project.handoffs = try parseStringArray(raw)
            default: throw ProfileError.invalidProfile("unknown YAML project key \(key)")
            }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty || rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let indent = rawLine.prefix { $0 == " " }.count
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else {
                throw ProfileError.invalidProfile("YAML lines must use key: value")
            }
            var key = String(trimmed[..<colon])
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                if current != nil { projects.append(current!); current = nil }
                inProjects = key == "projects"
                switch key {
                case "version": profile.version = Int(value) ?? -1
                case "roots": profile.roots = try parseStringArray(value)
                case "exclusions": profile.exclusions = try parseStringArray(value)
                case "max_results": profile.maxResults = Int(value) ?? -1
                case "projects": break
                default: throw ProfileError.invalidProfile("unknown YAML key \(key)")
                }
            } else {
                guard inProjects else { throw ProfileError.invalidProfile("unexpected YAML indentation") }
                if key.hasPrefix("- ") {
                    if current != nil { projects.append(current!) }
                    key = String(key.dropFirst(2))
                    current = GlobalRAGProfile.Project(match: "")
                }
                guard var project = current else { throw ProfileError.invalidProfile("project entry must start with - match") }
                try assign(key, value, to: &project)
                current = project
            }
        }
        if let current { projects.append(current) }
        profile.projects = projects
        try validate(profile)
        return profile
    }

    // MARK: - Discovery and retrieval

    static func buildSnapshot(
        profile: GlobalRAGProfile = loadProfile(),
        roots explicitRoots: [URL]? = nil,
        now: Date = Date(),
        persistSnapshot: Bool = true
    ) -> GlobalRAGSnapshot {
        let roots = normalizedRoots(explicitRoots ?? configuredRoots(profile: profile))
        let exclusions = Set((profile.exclusions + (UserDefaults.standard.stringArray(forKey: exclusionsDefaultsKey) ?? []))
            .map { $0.lowercased() })
        var records: [GlobalRAGRecord] = []
        var projectPaths: Set<String> = []

        for root in roots {
            for projectURL in projectDirectories(in: root, exclusions: exclusions) where projectPaths.count < maxProjects {
                let path = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard projectPaths.insert(path).inserted else { continue }
                let override = profile.projects.first { matches($0.match, projectURL: projectURL) }
                records.append(contentsOf: inspectProject(projectURL, override: override))
                if records.count >= maxRecords { break }
            }
            if records.count >= maxRecords { break }
        }
        records.append(contentsOf: profileOnlyRecords(profile: profile, discoveredPaths: projectPaths))
        records.append(contentsOf: discoverResearchCatalogs(under: roots))
        records = deduplicated(records: Array(records.prefix(maxRecords)))
        let snapshot = GlobalRAGSnapshot(
            builtAt: now,
            roots: roots.map(\.path),
            projectCount: projectPaths.count,
            records: records
        )
        if persistSnapshot {
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder.iso
            try? encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        }
        return snapshot
    }

    static func contextText(
        query: String,
        currentProject: String? = nil,
        kinds: Set<GlobalRAGRecord.Kind> = [],
        limit: Int? = nil,
        snapshot supplied: GlobalRAGSnapshot? = nil,
        includeMemory: Bool = true
    ) -> String {
        let profile = loadProfile()
        let snapshot = supplied ?? freshSnapshot() ?? buildSnapshot(profile: profile)
        let automaticLimit = min(profile.maxResults, automaticContextLimit)
        let boundedLimit = min(max(limit ?? automaticLimit, 1), 50)
        let scope = currentProject ?? FileManager.default.currentDirectoryPath
        let boundedQuery = String(query.prefix(500))
        let terms = SemanticIndex.terms(boundedQuery)
        let scored = snapshot.records.compactMap { record -> (GlobalRAGRecord, Float)? in
            guard kinds.isEmpty || kinds.contains(record.kind) else { return nil }
            let haystack = [record.title, record.detail, record.project, record.kind.rawValue].joined(separator: " ")
            var score = SemanticIndex.keywordOverlap(terms, in: haystack)
            if record.configured { score += 0.30 }
            if scopeMatches(record: record, scope: scope) { score += 0.22 }
            if terms.isEmpty, record.kind == .project { score += 0.10 }
            guard score > 0 || terms.isEmpty else { return nil }
            return (record, score)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending }
            return $0.1 > $1.1
        }
        let hits = Array(scored.prefix(boundedLimit))

        var lines = [
            "Global portfolio RAG — local, provider-neutral, profile v\(profile.version).",
            "Snapshot: \(snapshot.projectCount) discovered projects, \(snapshot.records.count) provenance records, built \(ISO8601DateFormatter().string(from: snapshot.builtAt)).",
            "Treat these as reuse candidates and historical context. Recheck the live checkout, installed SDKs, accounts, signing and release state before acting.",
            "Never infer authorization to publish, upload, submit, message or mutate another project."
        ]
        if hits.isEmpty {
            lines.append("No global match for “\(boundedQuery)”. Import/adjust a JSON or YAML profile, add a discovery root, or refresh the index.")
        } else {
            lines.append("")
            lines.append("Ranked context for “\(boundedQuery.isEmpty ? "portfolio overview" : boundedQuery)”: ")
            for (record, score) in hits {
                let path = record.evidencePath ?? record.projectPath ?? "profile"
                lines.append("• [\(record.kind.rawValue)] \(record.title) — \(record.project) (\(String(format: "%.2f", score)))")
                if !record.detail.isEmpty { lines.append("  \(record.detail)") }
                lines.append("  evidence: \(path)\(record.configured ? " [configured]" : " [discovered]")")
            }
        }

        // Global context is a cheap router, not a deep repository search. A
        // selected project can be inspected explicitly with
        // throttle_semantic_search, avoiding several cold index loads here.
        if includeMemory, !boundedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           kinds.isEmpty || kinds.contains(.memory) {
            let durable = DeltaMemStore.roots().compactMap { root -> (DeltaMemNode, Float)? in
                let score = SemanticIndex.keywordOverlap(terms, in: root.title + " " + root.body)
                return score > 0 ? (root, score) : nil
            }.sorted { $0.1 > $1.1 }.prefix(2)
            let sessions = TranscriptIndex.search(boundedQuery, limit: 3)
            if !durable.isEmpty || !sessions.isEmpty {
                lines.append("")
                lines.append("Relevant cross-session memory:")
                for (root, _) in durable {
                    let resolved = DeltaMemStore.resolve(rootId: root.id, scope: scope) ?? root.body
                    lines.append("• [durable memory] \(sanitized(root.title)) — \(sanitized(String(resolved.prefix(500))))")
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                for hit in sessions {
                    lines.append("• [prior session] \(hit.project) · \(formatter.string(from: hit.timestamp)) · session \(hit.sessionId) — \(sanitized(hit.snippet))")
                }
            }
        }
        lines.append("")
        lines.append("For deeper proof, call throttle_semantic_search with the returned repo path, then verify files/tests directly. Use search_sessions for prior decisions and throttle_recall for durable facts.")
        return lines.joined(separator: "\n")
    }

    static func refreshText() -> String {
        let snapshot = buildSnapshot()
        return "Global portfolio RAG refreshed locally: \(snapshot.projectCount) projects, \(snapshot.records.count) provenance records, \(snapshot.roots.count) roots. No repository or provider configuration was modified."
    }

    private static func freshSnapshot(maxAge: TimeInterval = snapshotMaxAge) -> GlobalRAGSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder.iso.decode(GlobalRAGSnapshot.self, from: data),
              Date().timeIntervalSince(snapshot.builtAt) >= 0,
              Date().timeIntervalSince(snapshot.builtAt) <= maxAge else { return nil }
        return snapshot
    }

    private static func configuredRoots(profile: GlobalRAGProfile) -> [URL] {
        let fm = FileManager.default
        let stored = UserDefaults.standard.stringArray(forKey: rootsDefaultsKey) ?? []
        let configured = profile.roots + stored
        if !configured.isEmpty {
            return configured.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
        }
        let home = fm.homeDirectoryForCurrentUser
        let conventional = ["GitHub", "Projects", "Developer"].map { home.appendingPathComponent($0, isDirectory: true) }
        return conventional.filter { fm.fileExists(atPath: $0.path) }
    }

    private static func normalizedRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        return roots.compactMap {
            let url = $0.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path != "/", url.path != FileManager.default.homeDirectoryForCurrentUser.path,
                  seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    private static func projectDirectories(in root: URL, exclusions: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        if isProject(root) { return [root] }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var queue: [(URL, Int)] = [(root, 0)]
        var projects: [URL] = []
        var scannedDirectories = 0
        while !queue.isEmpty, projects.count < maxProjects, scannedDirectories < 2_000 {
            let (parent, depth) = queue.removeFirst()
            guard depth < 3,
                  let children = try? fm.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }
            for child in children.prefix(500) {
                scannedDirectories += 1
                guard !ignoredDirectories.contains(child.lastPathComponent),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let resolved = child.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(prefix),
                      !exclusions.contains(child.lastPathComponent.lowercased()),
                      !exclusions.contains(resolved.path.lowercased()) else { continue }
                if isProject(resolved) {
                    projects.append(resolved)
                } else {
                    queue.append((resolved, depth + 1))
                }
            }
        }
        return projects
    }

    private static func isProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            ".git", "Package.swift", "project.yml", "package.json", "Cargo.toml",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
            "pubspec.yaml", "go.mod", "pyproject.toml", "Podfile"
        ]
        if markers.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) { return true }
        return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    private static func inspectProject(_ url: URL, override: GlobalRAGProfile.Project?) -> [GlobalRAGRecord] {
        let fm = FileManager.default
        let projectName = (override?.displayName).nilIfBlank ?? url.lastPathComponent
        var records: [GlobalRAGRecord] = [makeRecord(
            kind: .project, title: projectName,
            detail: override?.aliases.isEmpty == false ? "Aliases: \(override!.aliases.joined(separator: ", "))" : "Discovered local repository",
            project: projectName, projectPath: url.path, evidencePath: url.path,
            modifiedAt: modificationDate(url), configured: override != nil
        )]

        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let toolMarkers: [(String, String)] = [
            ("Package.swift", "Swift Package Manager"), ("project.yml", "XcodeGen"),
            ("package.json", "Node.js"), ("Cargo.toml", "Cargo"), ("go.mod", "Go modules"),
            ("pyproject.toml", "Python packaging"), ("Podfile", "CocoaPods"),
            ("build.gradle", "Gradle"), ("build.gradle.kts", "Gradle"),
            ("pubspec.yaml", "Dart / Flutter"), ("appcast.xml", "Sparkle")
        ]
        for (marker, tool) in toolMarkers where fm.fileExists(atPath: url.appendingPathComponent(marker).path) {
            records.append(makeRecord(kind: .tool, title: tool, detail: "Detected from \(marker)", project: projectName,
                                      projectPath: url.path, evidencePath: url.appendingPathComponent(marker).path,
                                      modifiedAt: modificationDate(url.appendingPathComponent(marker)), configured: false))
        }
        if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            let marker = names.first { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }!
            records.append(makeRecord(kind: .tool, title: "Xcode", detail: "Apple project/workspace detected", project: projectName,
                                      projectPath: url.path, evidencePath: url.appendingPathComponent(marker).path,
                                      modifiedAt: modificationDate(url.appendingPathComponent(marker)), configured: false))
        }
        let genericToolDirs = [(".github/workflows", "GitHub Actions"), ("fastlane", "fastlane"), ("scripts", "Project scripts")]
        for (relative, tool) in genericToolDirs where fm.fileExists(atPath: url.appendingPathComponent(relative).path) {
            records.append(makeRecord(kind: .tool, title: tool, detail: "Detected local automation", project: projectName,
                                      projectPath: url.path, evidencePath: url.appendingPathComponent(relative).path,
                                      modifiedAt: modificationDate(url.appendingPathComponent(relative)), configured: false))
        }

        let packageURL = url.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL), data.count <= 512_000,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let dependencies = Array(((json["dependencies"] as? [String: Any]) ?? [:]).keys)
                + Array(((json["devDependencies"] as? [String: Any]) ?? [:]).keys)
            for dependency in Set(dependencies).sorted().prefix(40) {
                records.append(makeRecord(kind: .capability, title: dependency, detail: "Declared package dependency",
                                          project: projectName, projectPath: url.path, evidencePath: packageURL.path,
                                          modifiedAt: modificationDate(packageURL), configured: false))
            }
            for script in ((json["scripts"] as? [String: Any]) ?? [:]).keys.sorted().prefix(30) {
                records.append(makeRecord(kind: .workflow, title: script, detail: "Declared package workflow",
                                          project: projectName, projectPath: url.path, evidencePath: packageURL.path,
                                          modifiedAt: modificationDate(packageURL), configured: false))
            }
        }

        var sourceNames: Set<String> = []
        var scanned = 0
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in enumerator {
                scanned += 1
                if scanned > maxScannedEntriesPerProject { break }
                if ignoredDirectories.contains(item.lastPathComponent),
                   (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants(); continue
                }
                let ext = item.pathExtension.lowercased()
                if sourceExtensions.contains(ext) {
                    let stem = item.deletingPathExtension().lastPathComponent
                    if stem.count >= 4, stem.count <= 80, stem.first?.isUppercase == true { sourceNames.insert(stem) }
                }
                let lower = item.lastPathComponent.lowercased()
                if workflowTerms.contains(where: lower.contains), ["sh", "zsh", "bash", "yml", "yaml", "rb"].contains(ext) {
                    records.append(makeRecord(kind: .workflow, title: item.deletingPathExtension().lastPathComponent,
                                              detail: "Discovered automation entry point", project: projectName,
                                              projectPath: url.path, evidencePath: item.path,
                                              modifiedAt: modificationDate(item), configured: false))
                }
            }
        }
        for name in sourceNames.sorted().prefix(40) {
            records.append(makeRecord(kind: .capability, title: name, detail: "Reusable source component candidate",
                                      project: projectName, projectPath: url.path, evidencePath: url.path,
                                      modifiedAt: nil, configured: false))
        }
        if let override {
            for value in override.capabilities { records.append(configuredRecord(.capability, value, projectName, url.path)) }
            for value in override.tools { records.append(configuredRecord(.tool, value, projectName, url.path)) }
            for value in override.workflows { records.append(configuredRecord(.workflow, value, projectName, url.path)) }
            for value in override.handoffs { records.append(configuredRecord(.handoff, value, projectName, url.path)) }
        }
        return records
    }

    private static func profileOnlyRecords(profile: GlobalRAGProfile, discoveredPaths: Set<String>) -> [GlobalRAGRecord] {
        profile.projects.flatMap { project -> [GlobalRAGRecord] in
            let discovered = discoveredPaths.contains { matches(project.match, path: $0, name: ( $0 as NSString).lastPathComponent) }
            guard !discovered else { return [] }
            let name = project.displayName.nilIfBlank ?? project.match
            var out = [configuredRecord(.project, name, name, nil)]
            out += project.capabilities.map { configuredRecord(.capability, $0, name, nil) }
            out += project.tools.map { configuredRecord(.tool, $0, name, nil) }
            out += project.workflows.map { configuredRecord(.workflow, $0, name, nil) }
            out += project.handoffs.map { configuredRecord(.handoff, $0, name, nil) }
            return out
        }
    }

    private static func discoverResearchCatalogs(under roots: [URL]) -> [GlobalRAGRecord] {
        let fm = FileManager.default
        var catalogs: [URL] = []
        for root in roots {
            let direct = root.appendingPathComponent("catalog.jsonl")
            if fm.fileExists(atPath: direct.path) { catalogs.append(direct) }
            if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for child in children.prefix(500) where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let candidate = child.appendingPathComponent("catalog.jsonl")
                    if fm.fileExists(atPath: candidate.path) { catalogs.append(candidate) }
                }
            }
        }
        var records: [GlobalRAGRecord] = []
        for catalog in catalogs.prefix(8) {
            guard let data = try? Data(contentsOf: catalog), data.count <= 64 * 1024 * 1024 else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(20_000) {
                guard let rowData = String(line).data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: rowData) as? [String: Any],
                      let title = row["title"] as? String,
                      let project = row["project"] as? String,
                      let libraryPath = row["library_path"] as? String else { continue }
                let sha = (row["sha256"] as? String).map { String($0.prefix(12)) } ?? "unknown"
                records.append(makeRecord(kind: .research, title: title, detail: "Local research catalog · SHA \(sha)",
                                          project: project, projectPath: nil,
                                          evidencePath: catalog.deletingLastPathComponent().appendingPathComponent(libraryPath).path,
                                          modifiedAt: modificationDate(catalog), configured: false))
                if records.count >= 4_000 { break }
            }
        }
        return records
    }

    private static func configuredRecord(_ kind: GlobalRAGRecord.Kind, _ title: String, _ project: String, _ path: String?) -> GlobalRAGRecord {
        makeRecord(kind: kind, title: title, detail: "Imported from the portable global RAG profile", project: project,
                   projectPath: path, evidencePath: profileURL.path, modifiedAt: modificationDate(profileURL), configured: true)
    }

    private static func makeRecord(
        kind: GlobalRAGRecord.Kind, title: String, detail: String, project: String,
        projectPath: String?, evidencePath: String?, modifiedAt: Date?, configured: Bool
    ) -> GlobalRAGRecord {
        let identity = [kind.rawValue, project, title, evidencePath ?? ""].joined(separator: "\u{1f}")
        return GlobalRAGRecord(
            id: ContentStore.sha256Hex(Data(identity.utf8)), kind: kind,
            title: sanitized(title), detail: sanitized(detail), project: sanitized(project),
            projectPath: projectPath, evidencePath: evidencePath, modifiedAt: modifiedAt,
            configured: configured
        )
    }

    private static func deduplicated(records: [GlobalRAGRecord]) -> [GlobalRAGRecord] {
        var byKey: [String: GlobalRAGRecord] = [:]
        for record in records {
            let key = [record.kind.rawValue, record.project.lowercased(), record.title.lowercased()].joined(separator: "|")
            if byKey[key] == nil || record.configured { byKey[key] = record }
        }
        return byKey.values.sorted {
            if $0.project == $1.project { return $0.title < $1.title }
            return $0.project < $1.project
        }
    }

    private static func matches(_ match: String, projectURL: URL) -> Bool {
        matches(match, path: projectURL.path, name: projectURL.lastPathComponent)
    }

    private static func matches(_ match: String, path: String, name: String) -> Bool {
        let normalized = NSString(string: match).expandingTildeInPath
        return normalized.caseInsensitiveCompare(path) == .orderedSame
            || match.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func scopeMatches(record: GlobalRAGRecord, scope: String) -> Bool {
        guard !scope.isEmpty else { return false }
        if let path = record.projectPath, scope.localizedCaseInsensitiveContains(path) || path.localizedCaseInsensitiveContains(scope) { return true }
        return scope.localizedCaseInsensitiveContains(record.project)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func sanitized(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        if sensitiveTerms.contains(where: lower.contains) { return "[redacted sensitive label]" }
        return String(clean.prefix(320))
    }

    private static func rejectSensitiveKeys(in object: Any) throws {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if sensitiveTerms.contains(where: key.lowercased().contains) { throw ProfileError.sensitiveField(key) }
                try rejectSensitiveKeys(in: value)
            }
        } else if let array = object as? [Any] {
            for value in array { try rejectSensitiveKeys(in: value) }
        }
    }

    private static func rejectSensitiveYAMLKeys(in text: String) throws {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "- ")).lowercased()
            if sensitiveTerms.contains(where: key.contains) { throw ProfileError.sensitiveField(key) }
        }
    }

    private static func jsonScalar(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let encoded = String(data: data, encoding: .utf8) else { return "[]" }
        return encoded
    }

    private static func parseStringArray(_ raw: String) throws -> [String] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw ProfileError.invalidProfile("YAML lists must use JSON-compatible flow syntax")
        }
        return values
    }

    private static func parseString(_ raw: String) throws -> String {
        guard let data = "[\(raw)]".data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first else {
            throw ProfileError.invalidProfile("YAML strings must be quoted")
        }
        return value
    }

    private static func parseOptionalString(_ raw: String) throws -> String? {
        raw == "null" ? nil : try parseString(raw)
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
