import Foundation
import ResearchVaultModel
@_exported import ThrottleVaultClient
import ThrottleVaultContract

// The NSXPC interfaces, `ResearchVaultCodeRequirement`, the connection
// factory, `ResearchVaultClient` and the Inbox batch reader are canonical in
// the standalone `ThrottleVaultClient` package, re-exported here so existing
// imports compile unchanged. This product module keeps only the endpoint
// policies: they bind a mach service to an immutable `VaultAuthorization`
// grant, which no client may construct or send.

public struct ResearchVaultQueryEndpointPolicy: Equatable, Sendable {
    public let machServiceName: String
    public let authorizedClient: ResearchVaultCodeIdentity
    public let authorization: VaultAuthorization

    public init(
        machServiceName: String,
        authorizedClient: ResearchVaultCodeIdentity,
        authorization: VaultAuthorization
    ) throws {
        guard ResearchVaultEndpointName.isValid(machServiceName),
              !authorization.projectKeys.isEmpty else {
            throw ResearchVaultXPCConfigurationError.invalidServiceName
        }
        self.machServiceName = machServiceName
        self.authorizedClient = authorizedClient
        self.authorization = authorization
    }
}

public struct ResearchVaultOwnerEndpointPolicy: Equatable, Sendable {
    public let machServiceName: String
    public let authorizedClient: ResearchVaultCodeIdentity
    public let authorization: VaultAuthorization

    public init(
        machServiceName: String,
        authorizedClient: ResearchVaultCodeIdentity,
        authorization: VaultAuthorization
    ) throws {
        guard ResearchVaultEndpointName.isValid(machServiceName),
              !authorization.projectKeys.isEmpty else {
            throw ResearchVaultXPCConfigurationError.invalidServiceName
        }
        self.machServiceName = machServiceName
        self.authorizedClient = authorizedClient
        self.authorization = authorization
    }
}

private enum ResearchVaultEndpointName {
    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }
}
