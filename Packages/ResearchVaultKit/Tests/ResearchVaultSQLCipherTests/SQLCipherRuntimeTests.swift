import Foundation
import XCTest
import ResearchVaultSQLCipher

final class SQLCipherRuntimeTests: XCTestCase {
    func testOfficialRuntimeEncryptsDatabaseHeaderAndReopens() throws {
        let directory = temporaryDirectory("runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("vault.ccsql")
        let key = Data(repeating: 0x71, count: 32)

        let evidence = try SQLCipherRuntime.probe(databaseURL: database, key: key)
        XCTAssertFalse(evidence.cipherVersion.isEmpty)
        XCTAssertTrue(evidence.plaintextHeaderAbsent)

        let reopened = try SQLCipherRuntime.verify(databaseURL: database, key: key)
        XCTAssertEqual(reopened.cipherVersion, evidence.cipherVersion)
        XCTAssertTrue(reopened.plaintextHeaderAbsent)
    }

    func testWrongKeyCannotReadSchema() throws {
        let directory = temporaryDirectory("wrong-key")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("vault.ccsql")
        _ = try SQLCipherRuntime.probe(
            databaseURL: database,
            key: Data(repeating: 0x31, count: 32)
        )

        XCTAssertThrowsError(
            try SQLCipherRuntime.verify(
                databaseURL: database,
                key: Data(repeating: 0x32, count: 32)
            )
        )
    }

    func testInvalidKeyLengthFailsBeforeCreatingDatabase() throws {
        let directory = temporaryDirectory("invalid-key")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("vault.ccsql")

        XCTAssertThrowsError(
            try SQLCipherRuntime.probe(databaseURL: database, key: Data(repeating: 0x01, count: 16))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchVaultSQLCipher-" + UUID().uuidString + "-" + suffix)
    }
}
