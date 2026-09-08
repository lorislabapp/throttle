import Foundation
import ResearchVaultModel
import Security

@objc public protocol ResearchVaultQueryXPCProtocol {
    func search(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func health(withReply reply: @escaping @Sendable (Data) -> Void)
}

@objc public protocol ResearchVaultOwnerXPCProtocol {
    func admitProjects(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func importReceipts(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func listQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func reviewQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func exportReceipts(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func promoteReasoning(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func queryReasoning(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public enum ResearchVaultXPCConfigurationError: Error, Equatable, Sendable {
    case invalidSigningIdentifier
    case invalidTeamIdentifier
    case invalidServiceName
    case malformedCodeRequirement(OSStatus)
}

public struct ResearchVaultCodeIdentity: Equatable, Sendable {
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(signingIdentifier: String, teamIdentifier: String) throws {
        guard Self.isIdentifier(signingIdentifier) else {
            throw ResearchVaultXPCConfigurationError.invalidSigningIdentifier
        }
        guard teamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
            throw ResearchVaultXPCConfigurationError.invalidTeamIdentifier
        }
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public var distributionRequirement: String {
        """
        anchor apple generic and identifier "\(signingIdentifier)" and \
        certificate leaf[subject.OU] = "\(teamIdentifier)" and \
        (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or \
        certificate leaf[field.1.2.840.113635.100.6.1.12] exists or \
        (certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists))
        """
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }
}

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

public enum ResearchVaultCodeRequirement {
    public static func validate(_ requirement: String) throws {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled)
        guard status == errSecSuccess, compiled != nil else {
            throw ResearchVaultXPCConfigurationError.malformedCodeRequirement(status)
        }
    }
}

public enum ResearchVaultXPCConnectionFactory {
    public static func queryConnection(
        machServiceName: String,
        serviceIdentity: ResearchVaultCodeIdentity
    ) throws -> NSXPCConnection {
        try ResearchVaultCodeRequirement.validate(serviceIdentity.distributionRequirement)
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ResearchVaultQueryXPCProtocol.self)
        connection.setCodeSigningRequirement(serviceIdentity.distributionRequirement)
        return connection
    }

    public static func ownerConnection(
        machServiceName: String,
        serviceIdentity: ResearchVaultCodeIdentity
    ) throws -> NSXPCConnection {
        try ResearchVaultCodeRequirement.validate(serviceIdentity.distributionRequirement)
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ResearchVaultOwnerXPCProtocol.self)
        connection.setCodeSigningRequirement(serviceIdentity.distributionRequirement)
        return connection
    }
}
