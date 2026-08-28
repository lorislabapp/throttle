import CryptoKit
import Foundation
import ResearchVaultGateway
import ResearchVaultKeychain
import ResearchVaultMCP
import ResearchVaultModel
import ResearchVaultSQLCipher
import ResearchVaultStore

@main
struct ResearchVaultMCPMain {
    static func main() async {
#if DEBUG
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            let master: SymmetricKey
#if DEBUG
            if configuration.usesEphemeralTestingKey {
                master = SymmetricKey(data: Data(repeating: 0x93, count: 32))
            } else {
                master = try KeychainVaultMasterKeyStore().loadOrCreate()
            }
#else
            master = try KeychainVaultMasterKeyStore().loadOrCreate()
#endif
            let vaultID = UUID(uuidString: "ac24788a-f55d-4da7-bbe9-8f4719bd1255")!
            let keys = VaultKeyDerivation.derive(masterKey: master, vaultID: vaultID)
            let store = try SQLCipherReceiptStore(
                databaseURL: configuration.databaseURL,
                key: keys.databaseKey
            )
            let gateway = ResearchVaultGateway(
                store: store,
                authorization: VaultAuthorization(
                    projectKeys: configuration.projectKeys,
                    maximumSensitivity: configuration.maximumSensitivity
                )
            )
            if let deepSearshRoot = configuration.deepSearshRoot {
                _ = try await gateway.importDeepSearshSnapshot(root: deepSearshRoot)
            }
            try FileManager.default.createDirectory(
                at: configuration.inboxURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            _ = try await gateway.importReceiptInbox(root: configuration.inboxURL)

            let handler = ResearchVaultMCPProtocolHandler(gateway: gateway)
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let response = await handler.handleLine(data) else { continue }
                FileHandle.standardOutput.write(response + Data("\n".utf8))
            }
            await store.close()
        } catch {
            FileHandle.standardError.write(Data("research-vault-mcp: startup failed\n".utf8))
            exit(1)
        }
#else
        // The direct stdio owner can be launched by any local process and has
        // no signed peer identity. It remains a Debug integration harness only;
        // production access must traverse the authenticated XPC service.
        FileHandle.standardError.write(
            Data("research-vault-mcp: direct Release mode disabled\n".utf8)
        )
        exit(1)
#endif
    }
}

private struct Configuration {
    let databaseURL: URL
    let inboxURL: URL
    let deepSearshRoot: URL?
    let projectKeys: Set<String>
    let maximumSensitivity: ResearchSensitivity
#if DEBUG
    let usesEphemeralTestingKey: Bool
#endif

    init(arguments: [String]) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Throttle/ResearchVault", isDirectory: true)
        var database = support.appendingPathComponent("vault.ccsql")
        var inbox = support.appendingPathComponent("Research Inbox", isDirectory: true)
        var deepSearsh: URL?
        var projects = Set<String>()
        var sensitivity = ResearchSensitivity.internal
#if DEBUG
        var testingKey = false
#endif
        var index = 0
        while index < arguments.count {
#if DEBUG
            if arguments[index] == "--ephemeral-testing-key" {
                testingKey = true
                index += 1
                continue
            }
#endif
            guard index + 1 < arguments.count else { throw ConfigurationError.invalidArguments }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--database": database = URL(fileURLWithPath: value)
            case "--inbox": inbox = URL(fileURLWithPath: value, isDirectory: true)
            case "--deepsearsh": deepSearsh = URL(fileURLWithPath: value, isDirectory: true)
            case "--project": projects.insert(value)
            case "--maximum-sensitivity":
                guard let parsed = ResearchSensitivity(rawValue: value) else {
                    throw ConfigurationError.invalidArguments
                }
                sensitivity = parsed
            default: throw ConfigurationError.invalidArguments
            }
            index += 2
        }
        if projects.isEmpty { projects = ["throttle"] }
        self.databaseURL = database
        self.inboxURL = inbox
        self.deepSearshRoot = deepSearsh
        self.projectKeys = projects
        self.maximumSensitivity = sensitivity
#if DEBUG
        self.usesEphemeralTestingKey = testingKey
#endif
    }
}

private enum ConfigurationError: Error { case invalidArguments }
