import CryptoKit
import Foundation
import XCTest
import ResearchVaultStore

final class VaultKeyDerivationTests: XCTestCase {
    func testDatabaseKeyIsDeterministicAndVaultScoped() {
        let master = SymmetricKey(data: Data(repeating: 0x44, count: 32))
        let firstID = UUID(uuidString: "5759a244-2ad7-49ee-9a1c-36b39cf1073c")!
        let secondID = UUID(uuidString: "26388ab9-9c87-48f7-be0e-b3736caa780e")!

        let first = VaultKeyDerivation.derive(masterKey: master, vaultID: firstID)
        let repeated = VaultKeyDerivation.derive(masterKey: master, vaultID: firstID)
        let second = VaultKeyDerivation.derive(masterKey: master, vaultID: secondID)

        XCTAssertEqual(first.databaseKey.count, 32)
        XCTAssertEqual(first.backupKey.count, 32)
        XCTAssertEqual(first.databaseKey, repeated.databaseKey)
        XCTAssertEqual(first.backupKey, repeated.backupKey)
        XCTAssertNotEqual(first.databaseKey, second.databaseKey)
        XCTAssertNotEqual(first.backupKey, second.backupKey)
        XCTAssertNotEqual(first.databaseKey, first.backupKey)
    }
}
