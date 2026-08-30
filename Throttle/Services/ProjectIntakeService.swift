import Foundation

/// Looks at a directory and says what kind of project it is, so Throttle can
/// propose the right starting plan instead of the same one everywhere.
///
/// Read-only, and cheap: it counts and samples rather than walking a whole tree,
/// because it runs when the user opens the Plan segment on a project it has never
/// seen.
enum ProjectIntakeService {

    enum Shape: String, Sendable, Equatable {
        /// Nothing to read. The idea itself is still to be worked out.
        case empty
        /// Code exists but no plan does. The work is to find what is missing, not
        /// to invent the product.
        case unplannedCode
        /// A plan is already there; intake has nothing to add.
        case planned
    }

    struct Survey: Sendable, Equatable {
        let shape: Shape
        let title: String
        let fileCount: Int
        let languages: [String]
        let hasReadme: Bool
        let hasGitHistory: Bool
        /// Plain sentences describing what was actually observed, so a proposed
        /// plan can be justified rather than asserted.
        let observations: [String]
    }

    private static let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", "build", "DerivedData", ".throttle",
        "Pods", ".venv", "dist", ".next", "vendor"
    ]

    private static let languageByExtension: [String: String] = [
        "swift": "Swift", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript",
        "py": "Python", "rs": "Rust", "go": "Go", "rb": "Ruby", "java": "Java",
        "kt": "Kotlin", "c": "C", "h": "C", "cpp": "C++", "cs": "C#", "php": "PHP"
    ]

    static func survey(repo: URL, fileManager: FileManager = .default) -> Survey {
        let title = repo.lastPathComponent
        guard let entries = try? fileManager.contentsOfDirectory(
            at: repo, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return Survey(shape: .empty, title: title, fileCount: 0, languages: [],
                          hasReadme: false, hasGitHistory: false,
                          observations: ["the directory could not be read"])
        }

        if fileManager.fileExists(atPath: repo.appendingPathComponent(".throttle/plan.json").path) {
            return Survey(shape: .planned, title: title, fileCount: entries.count,
                          languages: [], hasReadme: false, hasGitHistory: false,
                          observations: ["a plan already exists at .throttle/plan.json"])
        }

        var files: [URL] = []
        collect(into: &files, from: repo, fileManager: fileManager, budget: 400)

        var counts: [String: Int] = [:]
        for file in files {
            guard let language = languageByExtension[file.pathExtension.lowercased()] else { continue }
            counts[language, default: 0] += 1
        }
        let languages = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let hasReadme = entries.contains { $0.lastPathComponent.lowercased().hasPrefix("readme") }
        let hasGit = fileManager.fileExists(atPath: repo.appendingPathComponent(".git").path)

        var observations: [String] = []
        if files.isEmpty {
            observations.append("no source files")
        } else {
            observations.append("\(files.count) source file(s)"
                + (languages.isEmpty ? "" : ", mostly \(languages.prefix(2).joined(separator: " and "))"))
        }
        if hasReadme { observations.append("a README to read before assuming anything") }
        if hasGit { observations.append("git history to learn the project's direction from") }

        // A repository with only a README and a git init is still an idea, not a
        // codebase — treating it as code would skip the questions that matter.
        let shape: Shape = files.isEmpty ? .empty : .unplannedCode
        return Survey(shape: shape, title: title, fileCount: files.count,
                      languages: languages, hasReadme: hasReadme,
                      hasGitHistory: hasGit, observations: observations)
    }

    /// Depth-first with a hard budget: the answer is "roughly how much code is
    /// here", and walking a monorepo to get it exactly would not change the plan.
    private static func collect(into files: inout [URL], from directory: URL,
                                fileManager: FileManager, budget: Int) {
        guard files.count < budget,
              let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return }
        for entry in entries {
            guard files.count < budget else { return }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                guard !ignoredDirectories.contains(entry.lastPathComponent) else { continue }
                collect(into: &files, from: entry, fileManager: fileManager, budget: budget)
            } else if languageByExtension[entry.pathExtension.lowercased()] != nil {
                files.append(entry)
            }
        }
    }
}
