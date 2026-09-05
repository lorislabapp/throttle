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

    /// The bare file name is what the documentation asks for, and it is what
    /// worked through macOS 15. On macOS 27 it resolves to nothing: every agent
    /// reports `.notFound`, which this app rendered as "unavailable in this
    /// build" — a bundle that was in fact complete, signed, notarized and
    /// correct. Measured on 27.0 with a minimal probe app, the same plist
    /// answers `.notRegistered` when addressed by its path within the bundle.
    ///
    /// Neither spelling can be assumed, so the working one is chosen once:
    /// anything other than `.notFound` means the system resolved the file.
    private static let plistReference: String = {
        let full = "Contents/Library/LaunchAgents/" + plistName
        if SMAppService.agent(plistName: plistName).status != .notFound { return plistName }
        if SMAppService.agent(plistName: full).status != .notFound { return full }
        return plistName
    }()

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistReference)
    }
}
