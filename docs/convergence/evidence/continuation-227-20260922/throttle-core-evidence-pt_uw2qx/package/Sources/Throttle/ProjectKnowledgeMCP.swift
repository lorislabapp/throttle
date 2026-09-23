import Foundation
import ThrottleMCPContracts

enum ProjectKnowledgeMCP {
    static var schema: [String: Any] { ThrottleMCPSchemas.projectExploreSchema() }

    static func call(
        _ arguments: [String: Any]?,
        authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure> =
            PlanMCPTools.processAuthority
    ) -> String {
        let root = projectRoot(arguments?["project"] as? String)
        if let refusal = authorityRefusal(authority, root: root) { return refusal }
        guard let raw = arguments?["operation"] as? String,
              let operation = ProjectKnowledgeOperation(rawValue: raw) else {
            return "Refused: operation must be list, search or read."
        }
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        do {
            switch operation {
            case .list:
                return try explorer.list(
                    relativeDirectory: arguments?["path"] as? String ?? ""
                ).rendered()
            case .search:
                guard let query = arguments?["query"] as? String else {
                    return "Refused: search requires query."
                }
                return try explorer.search(
                    literal: query,
                    within: arguments?["path"] as? String ?? ""
                ).rendered()
            case .read:
                guard let path = arguments?["path"] as? String else {
                    return "Refused: read requires path."
                }
                return try explorer.read(
                    relativePath: path,
                    maximumCharacters: arguments?["max_chars"] as? Int ?? 12_000
                ).rendered()
            }
        } catch let error as ProjectKnowledgeError {
            return "Refused: project exploration failed (\(error))."
        } catch {
            return "Refused: project exploration could not be completed safely."
        }
    }

    private static func projectRoot(_ explicit: String?) -> URL {
        if let explicit {
            return URL(fileURLWithPath: explicit, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        var candidate = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<40 {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(".git").path
            ) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func authorityRefusal(
        _ authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>,
        root: URL
    ) -> String? {
        switch authority {
        case .failure(let failure):
            return PlanMCPAuthority.refusal(for: failure)
        case .success(let grant?):
            return grant.refusal(
                project: root.path,
                author: grant.author,
                operation: .read,
                requestedTaskID: nil
            )
        case .success(nil):
            return "Refused: project exploration requires an explicit read grant."
        }
    }
}
