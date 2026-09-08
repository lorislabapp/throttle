import CryptoKit
import Foundation

/// A receipt records the level actually observed; a successful shell command
/// must never be presented as a complete test inventory or physical acceptance.
/// Hashes identify inputs, not the author or truthfulness of an imported receipt.
struct WorkflowEvidenceReceipt: Codable, Sendable, Equatable {
    enum Scope: String, Codable, Sendable { case command, testInventory }
    enum Outcome: String, Codable, Sendable { case passed, failed, incomplete }

    var schemaVersion: Int = 1
    var id: UUID
    var scope: Scope
    var outcome: Outcome
    var inputStamp: String
    var commandDigest: String
    var startedAt: Date
    var finishedAt: Date
    var expectedTests: [String]?
    var passedTests: [String]?
    var skippedTests: [String]?

    static func command(_ command: String, stamp: String, startedAt: Date,
                        finishedAt: Date, result: (succeeded: Bool, revisionsUnchanged: Bool)) -> Self {
        Self(id: UUID(), scope: .command,
             outcome: !result.revisionsUnchanged ? .incomplete : (result.succeeded ? .passed : .failed),
             inputStamp: stamp,
             commandDigest: SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined(),
             startedAt: startedAt, finishedAt: finishedAt)
    }

    /// Conservative qualification. Command-only and older/unknown schemas never
    /// earn a test-completeness claim. Skips must be explicitly allowed by the
    /// caller's contract, not by data supplied inside the receipt.
    func provesCompleteTests(allowedSkips: Set<String> = []) -> Bool {
        guard schemaVersion == 1, scope == .testInventory, outcome == .passed,
              finishedAt >= startedAt, !inputStamp.isEmpty,
              commandDigest.utf8.count == 64,
              commandDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let expectedTests, let passedTests, let skippedTests,
              !expectedTests.isEmpty, !passedTests.isEmpty else { return false }
        let expected = Set(expectedTests), passed = Set(passedTests), skipped = Set(skippedTests)
        return !expected.contains("") && expected.count == expectedTests.count
            && passed.count == passedTests.count && skipped.count == skippedTests.count
            && passed.isDisjoint(with: skipped) && passed.union(skipped) == expected
            && skipped.isSubset(of: allowedSkips)
    }
}
