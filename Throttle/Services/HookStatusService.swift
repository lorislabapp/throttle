import Foundation

struct HookStatus: Sendable, Equatable {
    let sessionStartRouterInstalled: Bool
    let preCompactExtractorInstalled: Bool
    let killSwitchSet: Bool

    var activeCount: Int {
        var n = 0
        if sessionStartRouterInstalled { n += 1 }
        if preCompactExtractorInstalled { n += 1 }
        return n
    }
}

enum HookStatusService {
    static func currentStatus() -> HookStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let routerPath = home.appendingPathComponent(".claude/hooks/session-start-router.sh").path
        let compactPath = home.appendingPathComponent(".claude/hooks/pre-compact.sh").path
        let killSwitch = ProcessInfo.processInfo.environment["CLAUDE_DISABLE_TOKOPT_HOOKS"] == "1"
        return HookStatus(
            sessionStartRouterInstalled: FileManager.default.fileExists(atPath: routerPath),
            preCompactExtractorInstalled: FileManager.default.fileExists(atPath: compactPath),
            killSwitchSet: killSwitch
        )
    }
}
