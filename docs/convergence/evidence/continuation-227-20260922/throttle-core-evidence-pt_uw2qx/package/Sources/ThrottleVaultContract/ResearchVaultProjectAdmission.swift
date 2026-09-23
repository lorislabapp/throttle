import Foundation

/// Only the authenticated owner can admit a project. Importing receipt metadata
/// and narrowing a query never invoke this operation implicitly.
public struct ResearchVaultProjectAdmissionRequest: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let projectKeys: [String]

    public init(projectKeys: [String], contractVersion: Int = ResearchVaultIPCContract.currentVersion) {
        self.projectKeys = projectKeys
        self.contractVersion = contractVersion
    }

    public func validated() throws -> Self {
        guard contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultIPCValidationError.unsupportedContractVersion(contractVersion)
        }
        guard (1...64).contains(projectKeys.count), Set(projectKeys).count == projectKeys.count,
              projectKeys.allSatisfy({ key in
                  key.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
              }) else { throw ResearchVaultProjectAdmissionError.invalidProjects }
        return self
    }
}

public struct ResearchVaultProjectAdmissionResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let projectKeys: [String]

    public init(projectKeys: [String], contractVersion: Int = ResearchVaultIPCContract.currentVersion) {
        self.projectKeys = projectKeys
        self.contractVersion = contractVersion
    }
}

public enum ResearchVaultProjectAdmissionError: Error, Equatable, Sendable {
    case invalidProjects
    case ownerRequired
}
