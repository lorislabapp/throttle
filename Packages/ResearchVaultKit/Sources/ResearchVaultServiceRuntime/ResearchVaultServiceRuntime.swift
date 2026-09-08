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

            let endpoints = try Endpoints()
            let store = try makeStore()
            let retainedObjects = try await activateListeners(store: store, endpoints: endpoints)
            await ResearchVaultServiceLifetime.waitUntilCancelled()
            withExtendedLifetime(retainedObjects) {}
        } catch {
            FileHandle.standardError.write(
                Data("research-vault-agent: startup failed\n".utf8)
            )
            exit(1)
        }
    }

    private struct Endpoints {
        let cheatCodeAuthorization: VaultAuthorization
        let throttleAuthorization: VaultAuthorization
        let cheatCodePolicy: ResearchVaultQueryEndpointPolicy
        let throttleQueryPolicy: ResearchVaultQueryEndpointPolicy
        let throttleOwnerPolicy: ResearchVaultOwnerEndpointPolicy

        init() throws {
            cheatCodeAuthorization = VaultAuthorization(
                projectKeys: ["cheatcode", "throttle"],
                maximumSensitivity: .internal
            )
            throttleAuthorization = VaultAuthorization(
                projectKeys: ["cheatcode", "throttle"],
                maximumSensitivity: .restricted
            )
            cheatCodePolicy = try ResearchVaultQueryEndpointPolicy(
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
            throttleQueryPolicy = try ResearchVaultQueryEndpointPolicy(
                machServiceName: throttleQueryServiceName,
                authorizedClient: throttleIdentity,
                authorization: throttleAuthorization
            )
            throttleOwnerPolicy = try ResearchVaultOwnerEndpointPolicy(
                machServiceName: throttleOwnerServiceName,
                authorizedClient: throttleIdentity,
                authorization: throttleAuthorization
            )

        }
    }

    private static func makeStore() throws -> SQLCipherReceiptStore {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Throttle/ResearchVault", isDirectory: true)
        let rootKey = try KeychainVaultMasterKeyStore().loadOrCreate()
        let vaultID = UUID(uuid: (
            0xac, 0x24, 0x78, 0x8a, 0xf5, 0x5d, 0x4d, 0xa7,
            0xbb, 0xe9, 0x8f, 0x47, 0x19, 0xbd, 0x12, 0x55
        ))
        let keys = VaultKeyDerivation.derive(masterKey: rootKey, vaultID: vaultID)
        return try SQLCipherReceiptStore(
            databaseURL: support.appendingPathComponent("vault.ccsql"),
            key: keys.databaseKey
        )
    }

    private static func activateListeners(
        store: SQLCipherReceiptStore, endpoints: Endpoints
    ) async throws -> [AnyObject] {
        let cheatCodeGateway = ResearchVaultGateway(
            store: store,
            authorization: endpoints.cheatCodeAuthorization
        )
        let throttleGateway = try await ResearchVaultGateway.owner(
            store: store,
            baseline: endpoints.throttleAuthorization
        )
        let cheatCodeDelegate = try ResearchVaultQueryListenerDelegate(
            gateway: cheatCodeGateway,
            policy: endpoints.cheatCodePolicy
        )
        let throttleQueryDelegate = try ResearchVaultQueryListenerDelegate(
            gateway: throttleGateway,
            policy: endpoints.throttleQueryPolicy
        )
        let throttleOwnerDelegate = try ownerDelegate(gateway: throttleGateway, policy: endpoints.throttleOwnerPolicy)
        let cheatCodeListener = NSXPCListener(
            machServiceName: endpoints.cheatCodePolicy.machServiceName
        )
        let throttleQueryListener = NSXPCListener(
            machServiceName: endpoints.throttleQueryPolicy.machServiceName
        )
        let throttleOwnerListener = NSXPCListener(
            machServiceName: endpoints.throttleOwnerPolicy.machServiceName
        )
        cheatCodeDelegate.configure(cheatCodeListener)
        throttleQueryDelegate.configure(throttleQueryListener)
        throttleOwnerDelegate.configure(throttleOwnerListener)
        cheatCodeListener.activate()
        throttleQueryListener.activate()
        throttleOwnerListener.activate()

        return [
            cheatCodeDelegate, throttleQueryDelegate, throttleOwnerDelegate,
            cheatCodeListener, throttleQueryListener, throttleOwnerListener
        ]
    }

    private static func ownerDelegate(
        gateway: ResearchVaultGateway, policy: ResearchVaultOwnerEndpointPolicy
    ) throws -> ResearchVaultOwnerListenerDelegate {
        try ResearchVaultOwnerListenerDelegate(
            policy: policy,
            projectAdmitter: { request in
                try await gateway.admitProjects(request)
            },
            importer: { receipts in
                try await gateway.importReceiptsForReview(receipts)
            },
            quarantineLister: {
                try await gateway.quarantine()
            },
            reviewer: { request in
                try await gateway.review(request)
            },
            exporter: { request in
                try await gateway.exportApprovedReceipts(request)
            },
            reasoningPromoter: { request in
                try await gateway.refreshReasoningShadow(request)
            },
            reasoningQuerier: { request in
                try await gateway.reasoning(request)
            }
        )
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
