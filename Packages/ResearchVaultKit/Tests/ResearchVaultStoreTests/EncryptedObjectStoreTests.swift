import CryptoKit
import Foundation
import XCTest
import ResearchVaultStore

final class EncryptedObjectStoreTests: XCTestCase {
    func testRoundTripIsIdempotentAndDoesNotWritePlaintext() async throws {
        let directory = temporaryDirectory("roundtrip")
        let store = try EncryptedObjectStore(
            directory: directory,
            keys: keys(vaultID: UUID(uuidString: "e8ba4d91-bfdf-451a-90f8-92bd58f6227e")!)
        )
        let plaintext = Data("private research evidence".utf8)

        let first = try await store.put(plaintext)
        let second = try await store.put(plaintext)
        let restored = try await store.read(id: first.id)
        let envelope = try Data(contentsOf: directory.appendingPathComponent(first.id))

        XCTAssertEqual(first, second)
        XCTAssertEqual(restored, plaintext)
        XCTAssertNotEqual(envelope, plaintext)
        XCTAssertFalse(String(decoding: envelope, as: UTF8.self).contains("private research evidence"))
    }

    func testSamePlaintextHasDifferentIdentityAcrossVaults() async throws {
        let plaintext = Data("same evidence".utf8)
        let first = try EncryptedObjectStore(
            directory: temporaryDirectory("vault-a"),
            keys: keys(vaultID: UUID(uuidString: "2541f6b9-76de-47f9-9358-54f1613db446")!)
        )
        let second = try EncryptedObjectStore(
            directory: temporaryDirectory("vault-b"),
            keys: keys(vaultID: UUID(uuidString: "3a14f2eb-7fd8-4d8e-8888-91796dc636f6")!)
        )

        let firstObject = try await first.put(plaintext)
        let secondObject = try await second.put(plaintext)

        XCTAssertNotEqual(firstObject.id, secondObject.id)
        XCTAssertEqual(firstObject.plaintextSHA256, secondObject.plaintextSHA256)
    }

    func testTamperedEnvelopeFailsIntegrityCheck() async throws {
        let directory = temporaryDirectory("tamper")
        let store = try EncryptedObjectStore(
            directory: directory,
            keys: keys(vaultID: UUID(uuidString: "e8ba4d91-bfdf-451a-90f8-92bd58f6227e")!)
        )
        let object = try await store.put(Data("evidence".utf8))
        let url = directory.appendingPathComponent(object.id)
        var envelope = try Data(contentsOf: url)
        envelope[envelope.index(before: envelope.endIndex)] ^= 0xff
        try envelope.write(to: url, options: .atomic)

        do {
            _ = try await store.read(id: object.id)
            XCTFail("Tampered ciphertext must fail")
        } catch {
            XCTAssertEqual(error as? EncryptedObjectStoreError, .integrityFailure)
        }
    }

    func testObjectIDCannotEscapeStoreDirectory() async throws {
        let store = try EncryptedObjectStore(
            directory: temporaryDirectory("traversal"),
            keys: keys(vaultID: UUID(uuidString: "e8ba4d91-bfdf-451a-90f8-92bd58f6227e")!)
        )

        do {
            _ = try await store.read(id: "../secret")
            XCTFail("Traversal object ID must fail")
        } catch {
            XCTAssertEqual(error as? EncryptedObjectStoreError, .invalidObjectID)
        }
    }

    private func keys(vaultID: UUID) -> VaultKeyMaterial {
        VaultKeyMaterial.derive(
            masterKey: SymmetricKey(data: Data(repeating: 0x42, count: 32)),
            vaultID: vaultID
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchVaultKit-" + UUID().uuidString + "-" + suffix)
    }
}
