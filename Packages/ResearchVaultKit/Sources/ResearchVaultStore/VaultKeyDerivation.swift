import CryptoKit
import Foundation

public struct VaultDerivedKeys: Sendable {
    public let databaseKey: Data
    public let backupKey: Data
    public let objectKeys: VaultKeyMaterial

    public init(databaseKey: Data, backupKey: Data, objectKeys: VaultKeyMaterial) {
        self.databaseKey = databaseKey
        self.backupKey = backupKey
        self.objectKeys = objectKeys
    }
}

public enum VaultKeyDerivation {
    public static func derive(masterKey: SymmetricKey, vaultID: UUID) -> VaultDerivedKeys {
        let salt = Data(vaultID.uuidString.lowercased().utf8)
        let databaseKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Data("ResearchVault/database-encryption/v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let backupKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Data("ResearchVault/backup-encryption/v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        return VaultDerivedKeys(
            databaseKey: databaseKey,
            backupKey: backupKey,
            objectKeys: VaultKeyMaterial.derive(masterKey: masterKey, vaultID: vaultID)
        )
    }
}
