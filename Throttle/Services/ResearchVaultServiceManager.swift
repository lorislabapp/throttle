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
        case .notFound: .unavailable
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        @unknown default: .unavailable
        }
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
