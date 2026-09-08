import Foundation
import ThrottleShared

/// Keep the app hosting XCTest away from the user's account and App Group.
/// Explicitly injected fake services still execute their real state machines.
@MainActor
enum CompanionRuntime {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    static var defaultsSuiteName: String {
        isTesting
            ? "Throttle-Isolated-Test-Host-\(ProcessInfo.processInfo.processIdentifier)"
            : MirrorStorage.appGroupID
    }

    static let defaults: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Cannot open companion defaults suite")
        }
        return defaults
    }()
}
