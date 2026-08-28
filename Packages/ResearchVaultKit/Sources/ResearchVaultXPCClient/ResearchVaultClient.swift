import Foundation
import ResearchVaultIPCModel
import ResearchVaultModel

public enum ResearchVaultClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case serviceUnavailable
    case invalidResponse
    case responseTooLarge
    case rejected(ResearchVaultIPCErrorPayload.Code)
}

/// Secretless, short-lived client. Every call pins the service identity,
/// bounds both directions, and invalidates its connection after one reply.
public actor ResearchVaultClient {
    private let queryServiceName: String
    private let ownerServiceName: String?
    private let serviceIdentity: ResearchVaultCodeIdentity
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        queryServiceName: String,
        ownerServiceName: String? = nil,
        serviceIdentity: ResearchVaultCodeIdentity
    ) {
        self.queryServiceName = queryServiceName
        self.ownerServiceName = ownerServiceName
        self.serviceIdentity = serviceIdentity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func health() async throws -> ResearchVaultHealthResponse {
        let data = try await queryCall { proxy, reply in
            proxy.health(withReply: reply)
        }
        let response = try decode(ResearchVaultHealthResponse.self, from: data)
        guard response.contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultClientError.invalidResponse
        }
        return response
    }

    public func search(
        query: String,
        limit: Int = 8,
        maximumCharacters: Int = 12_000
    ) async throws -> ResearchVaultContextBundle {
        let request = try ResearchVaultSearchRequest(
            query: query,
            limit: limit,
            maximumCharacters: maximumCharacters
        ).validated()
        let encoded = try encoder.encode(request)
        guard encoded.count <= ResearchVaultIPCContract.maximumQueryBytes + 512 else {
            throw ResearchVaultClientError.invalidConfiguration
        }
        let data = try await queryCall { proxy, reply in
            proxy.search(encoded, withReply: reply)
        }
        let response = try decode(ResearchVaultContextBundle.self, from: data)
        guard response.contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultClientError.invalidResponse
        }
        return response
    }

    public func importReceipts(
        _ receipts: [ResearchReceipt]
    ) async throws -> ResearchVaultReceiptImportResponse {
        let request = try ResearchVaultReceiptImportRequest(receipts: receipts).validated()
        let encoded = try encoder.encode(request)
        guard encoded.count <= ResearchVaultIPCContract.maximumOwnerRequestBytes else {
            throw ResearchVaultClientError.invalidConfiguration
        }
        let data = try await ownerCall { proxy, reply in
            proxy.importReceipts(encoded, withReply: reply)
        }
        let response = try decode(ResearchVaultReceiptImportResponse.self, from: data)
        guard response.contractVersion == ResearchVaultIPCContract.currentVersion else {
            throw ResearchVaultClientError.invalidResponse
        }
        return response
    }

    private func queryCall(
        _ operation: @escaping @Sendable (
            ResearchVaultQueryXPCProtocol,
            @escaping @Sendable (Data) -> Void
        ) -> Void
    ) async throws -> Data {
        let connection = try ResearchVaultXPCConnectionFactory.queryConnection(
            machServiceName: queryServiceName,
            serviceIdentity: serviceIdentity
        )
        return try await call(
            connection: connection,
            proxy: { errorHandler in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
                    as? ResearchVaultQueryXPCProtocol else {
                    throw ResearchVaultClientError.serviceUnavailable
                }
                return proxy
            },
            operation: operation
        )
    }

    private func ownerCall(
        _ operation: @escaping @Sendable (
            ResearchVaultOwnerXPCProtocol,
            @escaping @Sendable (Data) -> Void
        ) -> Void
    ) async throws -> Data {
        guard let ownerServiceName else {
            throw ResearchVaultClientError.invalidConfiguration
        }
        let connection = try ResearchVaultXPCConnectionFactory.ownerConnection(
            machServiceName: ownerServiceName,
            serviceIdentity: serviceIdentity
        )
        return try await call(
            connection: connection,
            proxy: { errorHandler in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
                    as? ResearchVaultOwnerXPCProtocol else {
                    throw ResearchVaultClientError.serviceUnavailable
                }
                return proxy
            },
            operation: operation
        )
    }

    private func call<Proxy>(
        connection: NSXPCConnection,
        proxy: (@escaping @Sendable (Error) -> Void) throws -> Proxy,
        operation: @escaping @Sendable (Proxy, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ResearchVaultReplyGate(continuation: continuation)
            let connectionBox = ResearchVaultConnectionBox(connection)
            connection.interruptionHandler = {
                gate.fail(ResearchVaultClientError.serviceUnavailable)
            }
            connection.invalidationHandler = {
                gate.fail(ResearchVaultClientError.serviceUnavailable)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                gate.fail(ResearchVaultClientError.serviceUnavailable)
                connectionBox.connection.invalidate()
            }
            do {
                let remote = try proxy { _ in
                    gate.fail(ResearchVaultClientError.serviceUnavailable)
                    connectionBox.connection.invalidate()
                }
                connection.activate()
                operation(remote) { data in
                    if data.count > ResearchVaultIPCContract.maximumResponseBytes {
                        gate.fail(ResearchVaultClientError.responseTooLarge)
                    } else {
                        gate.succeed(data)
                    }
                    connectionBox.connection.invalidate()
                }
            } catch {
                gate.fail(error)
                connection.invalidate()
            }
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        if let value = try? decoder.decode(type, from: data) { return value }
        if let payload = try? decoder.decode(ResearchVaultIPCErrorPayload.self, from: data) {
            throw ResearchVaultClientError.rejected(payload.code)
        }
        throw ResearchVaultClientError.invalidResponse
    }
}

/// Canonical, non-secret service metadata shared by the owning helper and its
/// clients. Keeping these values in the SQLCipher-free client product prevents
/// consumers from drifting onto a similarly named or differently signed XPC
/// endpoint.
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

    /// Builds the least-privileged client surface intended for CheatCode.
    /// Owner/import operations remain unavailable by construction.
    public static func makeCheatCodeClient() throws -> ResearchVaultClient {
        ResearchVaultClient(
            queryServiceName: cheatCodeQueryServiceName,
            serviceIdentity: try ResearchVaultCodeIdentity(
                signingIdentifier: serviceSigningIdentifier,
                teamIdentifier: teamIdentifier
            )
        )
    }
}

private final class ResearchVaultConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class ResearchVaultReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Data) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
