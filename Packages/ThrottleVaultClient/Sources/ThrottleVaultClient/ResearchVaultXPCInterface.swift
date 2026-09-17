import Foundation
import Security
import ThrottleVaultContract

/// The two NSXPC interfaces of the vault service. Every operation carries one
/// JSON request and replies with one JSON payload from `ThrottleVaultContract`;
/// the connection, not the message, decides which interface a caller may use.
@objc public protocol ResearchVaultQueryXPCProtocol {
    func search(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func health(withReply reply: @escaping @Sendable (Data) -> Void)
}

@objc public protocol ResearchVaultOwnerXPCProtocol {
    func admitProjects(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func importReceipts(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func importDocuments(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func listQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func reviewQuarantine(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func exportReceipts(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func promoteReasoning(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
    func queryReasoning(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
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

/// Builds connections that pin the service's code identity before any message
/// is sent. Endpoint grants live in the service; a client never chooses one.
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
