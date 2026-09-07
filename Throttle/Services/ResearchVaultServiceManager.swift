import Foundation
import ServiceManagement

/// Explicit lifecycle control for the launchd-owned Research Vault query
/// service. Nothing registers at app startup: the user must opt in through a
/// deliberate UI action before macOS can launch the embedded agent.
enum ResearchVaultServiceManager {
    static let plistName = "com.lorislab.throttle.research-vault-agent.plist"
    static let queryServiceName = "com.lorislab.throttle.research-vault.query.throttle"
    static let ownerServiceName = "com.lorislab.throttle.research-vault.owner.throttle"

    enum State: Equatable, Sendable {
        case unavailable
        case disabled
        case enabled
        case requiresApproval
    }

    static var state: State {
        switch service.status {
        // `.notFound` is documented as a missing or malformed property list, and
        // that is how this was read: the workbench announced the vault as absent
        // from the build. On macOS 27 an agent that has simply never been
        // registered answers `.notFound` too — measured with a minimal probe app,
        // where registering by the same name succeeds and every later status is
        // correct. So the file's own presence decides: if the bundle carries the
        // plist, the honest reading is that nobody has enabled it yet.
        case .notFound: bundledPlistExists ? .disabled : .unavailable
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        @unknown default: .unavailable
        }
    }

    /// Registration only ever works by bare file name: addressing the same agent
    /// as `Contents/Library/LaunchAgents/<name>` reports a plausible status and
    /// then fails to register. The path is used to look for the file, never to
    /// name the service.
    private static var bundledPlistExists: Bool {
        FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchAgents")
                .appendingPathComponent(plistName).path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }
}
