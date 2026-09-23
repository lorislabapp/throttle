import Darwin
@testable import Throttle
import XCTest

final class ProjectKnowledgeRaceTests: XCTestCase {
    func testAncestorSymlinkSwapsNeverReadOutsideCanary() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("project")
        let directory = root.appendingPathComponent("docs")
        let parked = root.appendingPathComponent("parked")
        let outside = container.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try "INSIDE".write(to: directory.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        try "OUTSIDE_CANARY".write(to: outside.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        let group = DispatchGroup()
        let started = DispatchSemaphore(value: 0)
        group.enter()
        DispatchQueue.global().async {
            started.signal()
            for _ in 0..<1_000 where rename(directory.path, parked.path) == 0 {
                _ = symlink(outside.path, directory.path)
                _ = unlink(directory.path)
                _ = rename(parked.path, directory.path)
            }
            group.leave()
        }
        started.wait()
        for _ in 0..<1_000 {
            if let result = try? explorer.read(relativePath: "docs/file.md") {
                XCTAssertEqual(result.text, "INSIDE")
            }
        }
        group.wait()
        XCTAssertEqual(try explorer.read(relativePath: "docs/file.md").text, "INSIDE")
    }

    func testGrowingFileCannotExceedReadBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("growing.md")
        try Data(repeating: 65, count: 1_024).write(to: file)
        let explorer = ProjectKnowledgeExplorer(projectRoot: root)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CLOEXEC)
            if descriptor >= 0 {
                let chunk = [UInt8](repeating: 65, count: 4_096)
                for _ in 0..<64 { _ = chunk.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } }
                Darwin.close(descriptor)
            }
            group.leave()
        }
        for _ in 0..<128 {
            if let result = try? explorer.readFile("growing.md", maximumBytes: 4_096) {
                XCTAssertLessThanOrEqual(result.data.count, 4_096)
                XCTAssertTrue(result.data.allSatisfy { $0 == 65 })
            }
        }
        group.wait()
        XCTAssertThrowsError(try explorer.readFile("growing.md", maximumBytes: 4_096))
    }
}
