import Foundation

/// Audits the active project's local Claude Code settings without modifying
/// them. Local settings outrank the user-level `~/.claude/settings.json`, so
/// even a currently identical value pins the project and can hide later global
/// output-style changes.
enum OutputStyleShadowingDetector {
    struct Warning: Hashable, Sendable {
        let projectPath: String
        let settingsPath: String
        let localStyle: String
        let globalStyle: String?
    }

    static func detect(
        projectURL: URL?,
        globalSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) -> Warning? {
        guard let projectURL else { return nil }
        let localURL = projectURL.appendingPathComponent(".claude/settings.local.json")
        guard let local = outputStyle(at: localURL) else { return nil }
        return Warning(
            projectPath: projectURL.path,
            settingsPath: localURL.path,
            localStyle: local,
            globalStyle: outputStyle(at: globalSettingsURL)
        )
    }

    static func outputStyle(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["outputStyle"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func outputStyle(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return outputStyle(in: data)
    }
}
