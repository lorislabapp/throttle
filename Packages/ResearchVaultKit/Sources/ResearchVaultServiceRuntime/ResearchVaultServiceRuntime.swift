import CryptoKit
import Dispatch
import Foundation
import ResearchVaultGateway
import ResearchVaultKeychain
import ResearchVaultModel
import ResearchVaultSQLCipher
import ResearchVaultStore
import ResearchVaultXPC
import ResearchVaultXPCClient

public enum ResearchVaultServiceRuntime {
    public static let cheatCodeQueryServiceName =
        ResearchVaultServiceContract.cheatCodeQueryServiceName
    public static let throttleQueryServiceName =
        ResearchVaultServiceContract.throttleQueryServiceName
    public static let throttleOwnerServiceName =
        ResearchVaultServiceContract.throttleOwnerServiceName
    public static let signingIdentifier = ResearchVaultServiceContract.serviceSigningIdentifier
    public static let teamIdentifier = ResearchVaultServiceContract.teamIdentifier

    public static func run() async {
        do {
            guard CommandLine.arguments.count == 1 else {
                throw ResearchVaultServiceStartupError.argumentsForbidden
            }

            let cheatCodeAuthorization = VaultAuthorization(
                projectKeys: ["cheatcode", "throttle"],
                maximumSensitivity: .internal
            )
            let throttleAuthorization = VaultAuthorization(
                projectKeys: ["cheatcode", "throttle"],
                maximumSensitivity: .restricted
            )
            let cheatCodePolicy = try ResearchVaultQueryEndpointPolicy(
                machServiceName: cheatCodeQueryServiceName,
                authorizedClient: ResearchVaultCodeIdentity(
                    signingIdentifier: "com.kevinnadjarian.cheatcode",
                    teamIdentifier: teamIdentifier
                ),
                authorization: cheatCodeAuthorization
            )
            let throttleIdentity = try ResearchVaultCodeIdentity(
                signingIdentifier: "com.lorislab.throttle",
                teamIdentifier: teamIdentifier
            )
            let throttleQueryPolicy = try ResearchVaultQueryEndpointPolicy(
                machServiceName: throttleQueryServiceName,
                authorizedClient: throttleIdentity,
                authorization: throttleAuthorization
            )
            let throttleOwnerPolicy = try ResearchVaultOwnerEndpointPolicy(
                machServiceName: throttleOwnerServiceName,
                authorizedClient: throttleIdentity,
                authorization: throttleAuthorization
            )

            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Throttle/ResearchVault", isDirectory: true)
            let master = try KeychainVaultMasterKeyStore().loadOrCreate()
            let vaultID = UUID(uuidString: "ac24788a-f55d-4da7-bbe9-8f4719bd1255")!
            let keys = VaultKeyDerivation.derive(masterKey: master, vaultID: vaultID)
            let store = try SQLCipherReceiptStore(
                databaseURL: support.appendingPathComponent("vault.ccsql"),
                key: keys.databaseKey
            )
            let cheatCodeGateway = ResearchVaultGateway(
                store: store,
                authorization: cheatCodeAuthorization
            )
            let throttleGateway = ResearchVaultGateway(
                store: store,
                authorization: throttleAuthorization
            )
            let cheatCodeDelegate = try ResearchVaultQueryListenerDelegate(
                gateway: cheatCodeGateway,
                policy: cheatCodePolicy
            )
            let throttleQueryDelegate = try ResearchVaultQueryListenerDelegate(
                gateway: throttleGateway,
                policy: throttleQueryPolicy
            )
            let throttleOwnerDelegate = try ResearchVaultOwnerListenerDelegate(
                policy: throttleOwnerPolicy,
                importer: { receipts in
                    try await throttleGateway.importReceipts(receipts)
                }
            )
            let cheatCodeListener = NSXPCListener(
                machServiceName: cheatCodePolicy.machServiceName
            )
            let throttleQueryListener = NSXPCListener(
                machServiceName: throttleQueryPolicy.machServiceName
            )
            let throttleOwnerListener = NSXPCListener(
                machServiceName: throttleOwnerPolicy.machServiceName
            )
            cheatCodeDelegate.configure(cheatCodeListener)
            throttleQueryDelegate.configure(throttleQueryListener)
            throttleOwnerDelegate.configure(throttleOwnerListener)
            cheatCodeListener.activate()
            throttleQueryListener.activate()
            throttleOwnerListener.activate()

            let retainedObjects: [AnyObject] = [
                cheatCodeDelegate, throttleQueryDelegate, throttleOwnerDelegate,
                cheatCodeListener, throttleQueryListener, throttleOwnerListener,
            ]
            await ResearchVaultServiceLifetime.waitUntilCancelled()
            withExtendedLifetime(retainedObjects) {}
        } catch {
            FileHandle.standardError.write(
                Data("research-vault-agent: startup failed\n".utf8)
            )
            exit(1)
        }
    }
}

/// Keeps an async executable alive without blocking a cooperative thread.
///
/// `dispatchMain()` cannot be called from the cooperative executor used by an
/// async `@main` entry point. A cancellable suspension also gives tests and
/// future structured hosts a clean way to stop the runtime.
public enum ResearchVaultServiceLifetime {
    public static func waitUntilCancelled() async {
        do {
            try await Task.sleep(nanoseconds: .max)
        } catch is CancellationError {
            // Structured cancellation is the normal shutdown path.
        } catch {
            // Task.sleep currently only throws CancellationError. If that
            // contract changes, fail closed by letting the service return.
        }
    }
}

public enum ResearchVaultServiceStartupError: Error, Equatable, Sendable {
    case argumentsForbidden
}
