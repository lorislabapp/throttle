import Foundation

public enum ResearchVaultXPCConfigurationError: Error, Equatable, Sendable {
    case invalidSigningIdentifier
    case invalidTeamIdentifier
    case invalidServiceName
    case malformedCodeRequirement(OSStatus)
}

/// The code identity a client pins before trusting the vault service. The
/// requirement text is built here; compiling it against Code Signing Services
/// and opening a connection remain transport concerns outside this contract.
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

/// Canonical, non-secret service metadata shared by the owning helper and its
/// clients. Keeping these values in the contract prevents consumers from
/// drifting onto a similarly named or differently signed XPC endpoint.
public enum ResearchVaultServiceContract {
    public static let cheatCodeQueryServiceName =
        "com.lorislab.throttle.research-vault.query.cheatcode"
    public static let throttleQueryServiceName =
        "com.lorislab.throttle.research-vault.query.throttle"
    public static let throttleOwnerServiceName =
        "com.lorislab.throttle.research-vault.owner.throttle"
    public static let serviceSigningIdentifier =
        "com.lorislab.throttle.research-vault-agent"
    public static let teamIdentifier = "TDV6D5L785"
}
