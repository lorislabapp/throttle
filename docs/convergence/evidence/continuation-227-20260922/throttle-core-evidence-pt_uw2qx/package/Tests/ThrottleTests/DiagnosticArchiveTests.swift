@testable import Throttle
import XCTest

final class DiagnosticArchiveTests: XCTestCase {
    private var fixture: DiagnosticReport {
        DiagnosticReport(version: "3.6.0", build: "219", osVersion: "14.0",
                         usageEvents: 10, usageSnapshots: nil, savingsEvents: 0,
                         sessionHook: true, compactHook: false, killSwitch: false, exactState: .error)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func unzip(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    func test_archiveContainsExactlyTheReviewedSummaryAndNoAdjacentFiles() throws {
        let root = try temporaryDirectory()
        let canary = root.appendingPathComponent("private-log.txt")
        try Data("synthetic-secret-never-export".utf8).write(to: canary)
        let archive = try DiagnosticArchive.write(fixture, to: root, temporaryRoot: root)
        let entries = try unzip(["-Z1", archive.path]).split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(entries), ["report/", "report/summary.txt"])
        XCTAssertEqual(entries.count, 2)
        let content = try unzip(["-p", archive.path, "report/summary.txt"])
        XCTAssertEqual(content, fixture.text)
        XCTAssertFalse(content.contains("synthetic-secret-never-export"))
        XCTAssertFalse(content.contains(root.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["private-log.txt", archive.lastPathComponent])
    }

    func test_exportUsesTheFrozenValueAndSanitizesCanariesInsideTheZip() throws {
        let root = try temporaryDirectory()
        var liveReport = fixture
        liveReport.version = "/Users/synthetic/private"
        liveReport.build = "sk-synthetic-secret"
        let reviewed = liveReport
        liveReport.usageEvents = 999
        let archive = try DiagnosticArchive.write(reviewed, to: root, temporaryRoot: root)
        let content = try unzip(["-p", archive.path, "report/summary.txt"])
        XCTAssertEqual(content, reviewed.text)
        XCTAssertNotEqual(content, liveReport.text)
        XCTAssertFalse(content.contains("/Users/synthetic/private"))
        XCTAssertFalse(content.contains("sk-synthetic-secret"))
    }

    func test_repeatedExportsArePrivateDistinctAndPreserveTheFirstArchive() throws {
        let root = try temporaryDirectory()
        let first = try DiagnosticArchive.write(fixture, to: root, temporaryRoot: root)
        let original = try Data(contentsOf: first)
        let second = try DiagnosticArchive.write(fixture, to: root, temporaryRoot: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), original)
        for archive in [first, second] {
            let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       [first.lastPathComponent, second.lastPathComponent])
    }

    func test_invalidDestinationDoesNotReplaceAFileOrLeaveStagingData() throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("not-a-directory")
        let original = Data("keep-this-fixture".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try DiagnosticArchive.write(fixture, to: destination, temporaryRoot: root))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["not-a-directory"])
    }
}
