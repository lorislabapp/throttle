import Foundation

/// Turns a real Xcode result bundle into a test-inventory receipt.
///
/// A command's exit code says a command ran. It does not say which tests
/// existed, which of them finished, or which were skipped — and a receipt that
/// claimed complete coverage from an exit code would be the exact confusion
/// `WorkflowEvidenceReceipt` was written to prevent. This importer is what
/// makes the stronger claim reachable: it reads the inventory Xcode itself
/// recorded, and refuses to produce one when the bundle does not support it.
enum WorkflowResultImporter {

    enum ImportError: Error, Equatable {
        case toolUnavailable
        case bundleUnreadable(String)
        case unexpectedShape(String)
        case noCases
    }

    struct Inventory: Equatable, Sendable {
        /// Every case the run knew about, whatever became of it.
        let expected: [String]
        let passed: [String]
        let skipped: [String]
        /// Cases that neither passed nor were skipped: failures, and anything
        /// the bundle reports in a state this importer will not interpret.
        let unresolved: [String]

        var isComplete: Bool { unresolved.isEmpty && !expected.isEmpty }
    }

    /// Reads the tree `xcresulttool get test-results tests` produces. Parsing
    /// the documented JSON rather than the bundle format keeps this honest
    /// about what it can know, and it is the same shape the evidence verifier
    /// already validates in CI.
    static func inventory(fromTestsJSON data: Data) throws -> Inventory {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch {
            throw ImportError.bundleUnreadable("tests.json is not JSON")
        }
        guard let object = root as? [String: Any],
              let nodes = object["testNodes"] as? [Any], !nodes.isEmpty else {
            throw ImportError.unexpectedShape("no testNodes")
        }
        var expected: [String] = []
        var passed: [String] = []
        var skipped: [String] = []
        var unresolved: [String] = []
        var seen = Set<String>()

        func walk(_ value: Any) throws {
            if let list = value as? [Any] {
                for item in list { try walk(item) }
                return
            }
            guard let node = value as? [String: Any] else { return }
            if node["nodeType"] as? String == "Test Case" {
                guard let identifier = node["nodeIdentifier"] as? String, !identifier.isEmpty else {
                    throw ImportError.unexpectedShape("a test case without an identifier")
                }
                guard seen.insert(identifier).inserted else {
                    throw ImportError.unexpectedShape("duplicate case " + identifier)
                }
                expected.append(identifier)
                switch node["result"] as? String {
                case "Passed": passed.append(identifier)
                case "Skipped": skipped.append(identifier)
                default: unresolved.append(identifier)
                }
            }
            if let children = node["children"] { try walk(children) }
        }
        try walk(nodes)
        guard !expected.isEmpty else { throw ImportError.noCases }
        return Inventory(expected: expected.sorted(), passed: passed.sorted(),
                         skipped: skipped.sorted(), unresolved: unresolved.sorted())
    }

    /// Runs `xcresulttool` against a bundle on disk. Kept separate from the
    /// parsing so the rules above can be tested without Xcode.
    static func inventory(fromBundle url: URL, timeout: TimeInterval = 120) throws -> Inventory {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.bundleUnreadable(url.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcresulttool", "get", "test-results", "tests",
                             "--path", url.path, "--compact"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { throw ImportError.toolUnavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError.bundleUnreadable("xcresulttool exited \(process.terminationStatus)")
        }
        return try inventory(fromTestsJSON: data)
    }

    /// Upgrades a command receipt to a test-inventory one. The command's own
    /// outcome still governs: a receipt whose inputs changed underneath it, or
    /// whose command failed, stays what it was — an inventory does not rescue
    /// a run that was never trustworthy.
    static func upgraded(
        _ receipt: WorkflowEvidenceReceipt, with inventory: Inventory
    ) -> WorkflowEvidenceReceipt {
        guard receipt.scope == .command, receipt.outcome == .passed else { return receipt }
        var upgraded = receipt
        upgraded.scope = .testInventory
        upgraded.expectedTests = inventory.expected
        upgraded.passedTests = inventory.passed
        upgraded.skippedTests = inventory.skipped
        upgraded.outcome = inventory.isComplete ? .passed : .incomplete
        return upgraded
    }
}
