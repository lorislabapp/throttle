import CryptoKit
import Foundation

public struct VaultKeyMaterial: Sendable {
    fileprivate let encryptionKey: SymmetricKey
    fileprivate let identityKey: SymmetricKey

    public static func derive(masterKey: SymmetricKey, vaultID: UUID) -> VaultKeyMaterial {
        let salt = Data(vaultID.uuidString.lowercased().utf8)
        return VaultKeyMaterial(
            encryptionKey: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey,
                salt: salt,
                info: Data("ResearchVault/object-encryption/v1".utf8),
                outputByteCount: 32
            ),
            identityKey: HKDF<SHA256>.deriveKey(
                inputKeyMaterial: masterKey,
                salt: salt,
                info: Data("ResearchVault/object-identity/v1".utf8),
                outputByteCount: 32
            )
        )
    }
}

public struct StoredObject: Equatable, Sendable {
    public let id: String
    public let plaintextSHA256: String
    public let byteCount: Int

    public init(id: String, plaintextSHA256: String, byteCount: Int) {
        self.id = id
        self.plaintextSHA256 = plaintextSHA256
        self.byteCount = byteCount
    }
}

public enum EncryptedObjectStoreError: Error, Equatable, Sendable {
    case invalidObjectID
    case objectNotFound
    case invalidEnvelope
    case integrityFailure
    case identityCollision
}

/// Encrypted content-addressed storage scoped to one vault.
///
/// Object filenames are HMAC-SHA256 values produced with a per-vault identity
/// key. A public plaintext hash therefore cannot be used to probe whether a
/// known document exists in a vault. Contents use randomized AES-GCM envelopes.
public actor EncryptedObjectStore {
    private let directory: URL
    private let keys: VaultKeyMaterial
    private let fileManager: FileManager

    public init(
        directory: URL,
        keys: VaultKeyMaterial,
        fileManager: FileManager = .default
    ) throws {
        self.directory = directory
        self.keys = keys
        self.fileManager = fileManager
        try Self.prepareDirectory(directory, fileManager: fileManager)
    }

    public func put(_ plaintext: Data) throws -> StoredObject {
        let plaintextDigest = SHA256.hash(data: plaintext)
        let plaintextHash = Self.hex(plaintextDigest)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(plaintextDigest),
            using: keys.identityKey
        )
        let objectID = Self.hex(authentication)
        let destination = try objectURL(id: objectID)

        if fileManager.fileExists(atPath: destination.path) {
            let existing = try read(id: objectID)
            guard existing == plaintext else {
                throw EncryptedObjectStoreError.identityCollision
            }
            return StoredObject(
                id: objectID,
                plaintextSHA256: plaintextHash,
                byteCount: plaintext.count
            )
        }

        let sealed = try AES.GCM.seal(plaintext, using: keys.encryptionKey)
        guard let combined = sealed.combined else {
            throw EncryptedObjectStoreError.invalidEnvelope
        }
        try combined.write(to: destination, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        return StoredObject(
            id: objectID,
            plaintextSHA256: plaintextHash,
            byteCount: plaintext.count
        )
    }

    public func read(id: String) throws -> Data {
        let url = try objectURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw EncryptedObjectStoreError.objectNotFound
        }
        let envelope = try Data(contentsOf: url, options: [.mappedIfSafe])
        do {
            let box = try AES.GCM.SealedBox(combined: envelope)
            let plaintext = try AES.GCM.open(box, using: keys.encryptionKey)
            let digest = SHA256.hash(data: plaintext)
            let expectedID = Self.hex(
                HMAC<SHA256>.authenticationCode(
                    for: Data(digest),
                    using: keys.identityKey
                )
            )
            guard Self.constantTimeEquals(id, expectedID) else {
                throw EncryptedObjectStoreError.integrityFailure
            }
            return plaintext
        } catch let error as EncryptedObjectStoreError {
            throw error
        } catch {
            throw EncryptedObjectStoreError.integrityFailure
        }
    }

    public func contains(id: String) throws -> Bool {
        fileManager.fileExists(atPath: try objectURL(id: id).path)
    }

    private func objectURL(id: String) throws -> URL {
        guard id.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw EncryptedObjectStoreError.invalidObjectID
        }
        return directory.appendingPathComponent(id, isDirectory: false)
    }

    private static func prepareDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

