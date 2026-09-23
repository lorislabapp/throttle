import Foundation

public struct VaultAuthorization: Equatable, Sendable {
    public let projectKeys: Set<String>
    public let maximumSensitivity: ResearchSensitivity

    public init(projectKeys: Set<String>, maximumSensitivity: ResearchSensitivity) {
        self.projectKeys = projectKeys
        self.maximumSensitivity = maximumSensitivity
    }

    public func permits(projectKey: String, sensitivity: ResearchSensitivity) -> Bool {
        projectKeys.contains(projectKey) && sensitivity <= maximumSensitivity
    }
}

public enum VaultAuthorizationError: Error, Equatable, Sendable {
    case denied(projectKey: String, sensitivity: ResearchSensitivity)
}

