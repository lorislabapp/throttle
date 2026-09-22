import Foundation
import Security
@testable import ThrottleShared
import XCTest

/// All calls use injected in-memory operations; no Security function or secret is read.
final class KeychainStoreTests: XCTestCase {
    private final class Backend {
        var value = Data("synthetic-old".utf8)
        var calls: [String] = []
        var updateStatuses: [OSStatus] = [errSecSuccess]
        var addStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        var queries: [[String: Any]] = []

        var operations: KeychainStore.Operations {
            .init(update: { query, changes in
                self.calls.append("update")
                self.queries.append(query)
                let status = self.updateStatuses.removeFirst()
                if status == errSecSuccess {
                    guard let value = changes[kSecValueData as String] as? Data else {
                        XCTFail("Expected data in update fixture"); return errSecDecode
                    }
                    self.value = value
                }
                return status
            }, add: { query in
                self.calls.append("add")
                self.queries.append(query)
                if self.addStatus == errSecSuccess {
                    guard let value = query[kSecValueData as String] as? Data else {
                        XCTFail("Expected data in add fixture"); return errSecDecode
                    }
                    self.value = value
                }
                return self.addStatus
            }, delete: { query in
                self.calls.append("delete")
                self.queries.append(query)
                if self.deleteStatus == errSecSuccess { self.value = Data() }
                return self.deleteStatus
            })
        }
    }

    func testExistingCredentialIsUpdatedWithoutDeleteOrAdd() {
        let backend = Backend()
        XCTAssertTrue(KeychainStore.set("synthetic-new", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update"])
        XCTAssertEqual(backend.value, Data("synthetic-new".utf8))
    }

    func testLockedKeychainFailurePreservesPreviousCredential() {
        let backend = Backend()
        backend.updateStatuses = [errSecInteractionNotAllowed]
        XCTAssertFalse(KeychainStore.set("synthetic-new", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update"])
        XCTAssertEqual(backend.value, Data("synthetic-old".utf8))
    }

    func testOnlyMissingItemPermitsAdd() {
        let backend = Backend()
        backend.updateStatuses = [errSecItemNotFound]
        XCTAssertTrue(KeychainStore.set("synthetic-new", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update", "add"])
        XCTAssertEqual(backend.value, Data("synthetic-new".utf8))
        XCTAssertEqual(backend.queries.last?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testConcurrentAddRetriesUpdateOnceWithoutDeleting() {
        let backend = Backend()
        backend.updateStatuses = [errSecItemNotFound, errSecSuccess]
        backend.addStatus = errSecDuplicateItem
        XCTAssertTrue(KeychainStore.set("synthetic-new", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update", "add", "update"])
    }

    func testFailedAddReturnsFailureWithoutDelete() {
        let backend = Backend()
        backend.updateStatuses = [errSecItemNotFound]
        backend.addStatus = errSecAuthFailed
        XCTAssertFalse(KeychainStore.set("synthetic-new", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update", "add"])
    }

    func testExplicitDeletionReportsActualFailureAndMissingIsSuccess() {
        let backend = Backend()
        backend.deleteStatus = errSecInteractionNotAllowed
        XCTAssertFalse(KeychainStore.set(nil, account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.value, Data("synthetic-old".utf8))
        backend.deleteStatus = errSecItemNotFound
        XCTAssertTrue(KeychainStore.set(nil, account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["delete", "delete"])
    }

    func testEmptyStringIsAValueAndDoesNotDelete() {
        let backend = Backend()
        XCTAssertTrue(KeychainStore.set("", account: "fixture", using: backend.operations))
        XCTAssertEqual(backend.calls, ["update"])
        XCTAssertEqual(backend.value, Data())
    }

    func testCustomServicePreservesCredentialNamespaceOnUpdateAndAdd() {
        let backend = Backend()
        backend.updateStatuses = [errSecItemNotFound]
        XCTAssertTrue(KeychainStore.set("synthetic", account: "key",
                                       service: "com.lorislab.throttle.anthropic", using: backend.operations))
        for query in backend.queries {
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.lorislab.throttle.anthropic")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "key")
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        }
    }

    func testLicenseJSONBytesRemainCompatibleAndFailedRenewalKeepsThem() throws {
        let backend = Backend()
        let payload = ["licenseKey": "synthetic-é", "jwt": "synthetic-token"]
        let encoded = try JSONEncoder().encode(payload)
        let value = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let service = "com.lorislab.throttle.license"
        XCTAssertTrue(KeychainStore.set(value, account: "current", service: service, using: backend.operations))
        XCTAssertEqual(backend.value, encoded)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: backend.value), payload)
        backend.updateStatuses = [errSecInteractionNotAllowed]
        XCTAssertFalse(KeychainStore.set("replacement", account: "current",
                                        service: service, using: backend.operations))
        XCTAssertEqual(backend.value, encoded)
        XCTAssertEqual(backend.calls, ["update", "update"])
        for query in backend.queries {
            XCTAssertEqual(query[kSecAttrService as String] as? String, service)
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, "current")
        }
    }

    func testReadDistinguishesMissingFromLockedAndMalformedValues() {
        XCTAssertEqual(KeychainStore.read(account: "fixture", using: { _ in
            (errSecItemNotFound, nil)
        }), .missing)
        XCTAssertEqual(KeychainStore.read(account: "fixture", using: { _ in
            (errSecInteractionNotAllowed, nil)
        }), .unavailable(errSecInteractionNotAllowed))
        XCTAssertEqual(KeychainStore.read(account: "fixture", using: { _ in
            (errSecSuccess, Data([0xFF]))
        }), .unavailable(errSecDecode))
        XCTAssertEqual(KeychainStore.read(account: "fixture", using: { _ in
            (errSecSuccess, nil)
        }), .unavailable(errSecDecode))
    }

    func testReadPreservesEmptyAndNonemptyFoundValues() {
        for value in ["", "synthetic-existing"] {
            XCTAssertEqual(KeychainStore.read(account: "fixture", using: { query in
                XCTAssertEqual(query[kSecAttrService as String] as? String, "com.lorislab.throttle")
                XCTAssertEqual(query[kSecAttrAccount as String] as? String, "fixture")
                return (errSecSuccess, Data(value.utf8))
            }), .found(value))
        }
    }
}
