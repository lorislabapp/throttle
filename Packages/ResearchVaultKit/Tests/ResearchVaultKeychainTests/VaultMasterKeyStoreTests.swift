import CryptoKit
import Foundation
import XCTest
import ResearchVaultKeychain

final class VaultMasterKeyStoreTests: XCTestCase {
    func testFixedStoreRequiresExactly256Bits() throws {
        XCTAssertThrowsError(try FixedVaultMasterKeyStore(bytes: Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(
                error as? VaultMasterKeyStoreError,
                .invalidFixedKeyLength(31)
            )
        }

        let store = try FixedVaultMasterKeyStore(bytes: Data(repeating: 0x8a, count: 32))
        let keyData = try store.loadOrCreate().withUnsafeBytes { Data($0) }
        XCTAssertEqual(keyData, Data(repeating: 0x8a, count: 32))
    }
}
