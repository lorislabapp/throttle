import CryptoKit
import Foundation
import Security

public protocol VaultMasterKeyStore: Sendable {
    func loadOrCreate() throws -> SymmetricKey
}

public enum VaultMasterKeyStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidStoredKeyLength(Int)
    case invalidFixedKeyLength(Int)
}

/// Device-bound Keychain storage for the root vault key.
///
/// The item is deliberately non-synchronizable and only available while the
/// device is unlocked. Project/vault keys are derived from this root; the root
/// is never written to preferences, logs, command arguments or database files.
public final class KeychainVaultMasterKeyStore: VaultMasterKeyStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "com.lorislab.throttle.research-vault.keys",
        account: String = "master-v1",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadOrCreate() throws -> SymmetricKey {
        switch try loadExisting() {
        case let .some(key): return key
        case .none: break
        }

        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw VaultMasterKeyStoreError.keychain(randomStatus)
        }

        var attributes = baseQuery()
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData] = bytes
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            guard let raced = try loadExisting() else {
                throw VaultMasterKeyStoreError.keychain(addStatus)
            }
            return raced
        }
        guard addStatus == errSecSuccess else {
            throw VaultMasterKeyStoreError.keychain(addStatus)
        }
        return SymmetricKey(data: bytes)
    }

    private func loadExisting() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw VaultMasterKeyStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw VaultMasterKeyStoreError.invalidStoredKeyLength(0)
        }
        guard data.count == 32 else {
            throw VaultMasterKeyStoreError.invalidStoredKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}

public struct FixedVaultMasterKeyStore: VaultMasterKeyStore, Sendable {
    private let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw VaultMasterKeyStoreError.invalidFixedKeyLength(bytes.count)
        }
        self.bytes = bytes
    }

    public func loadOrCreate() throws -> SymmetricKey {
        SymmetricKey(data: bytes)
    }
}

