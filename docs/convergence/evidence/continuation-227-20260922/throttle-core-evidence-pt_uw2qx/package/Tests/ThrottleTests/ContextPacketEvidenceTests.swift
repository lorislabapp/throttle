@testable import Throttle
import XCTest

final class ContextPacketEvidenceTests: XCTestCase {
    private var folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var savedBase = ContentStore.baseDir

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedBase = ContentStore.baseDir
        ContentStore.baseDir = folder
    }

    override func tearDownWithError() throws {
        ContentStore.baseDir = savedBase
        try FileManager.default.removeItem(at: folder)
    }

    func test_corruptionCannotRehydrateOrProduceAValidPointer() throws {
        let original = Data("original".utf8)
        let hash = try XCTUnwrap(ContentStore.put(original))
        try Data("modified".utf8).write(to: folder.appendingPathComponent(hash + ".blob"))
        XCTAssertNil(ContentStore.get(hash))
        XCTAssertNil(ContentStore.put(original))
    }

    func test_pointerRequiresAnExactHash() throws {
        let hash = try XCTUnwrap(ContentStore.put(Data("original".utf8)))
        XCTAssertNil(ContentStore.get("../" + hash))
        XCTAssertNotNil(ContentStore.get(hash.uppercased()))
    }

    func test_numberingAndMetadataStayInsideTheContextBudget() {
        for count in [100, 200, 500, 900] {
            let text = Array(repeating: "a", count: count).joined(separator: "\n")
            for budget in [1_000, 1_500, 2_000] {
                let packet = ContextFirewall.packet(text: text, source: "log", maxCharacters: budget)
                XCTAssertLessThanOrEqual(packet.returnedCharacters, budget)
            }
        }
    }

    func test_sourceMetadataCannotExhaustTheBudget() {
        let packet = ContextFirewall.packet(text: "error: failure", source: String(repeating: "x", count: 10_000),
                                             maxCharacters: 1_000, untrusted: true)
        XCTAssertLessThanOrEqual(packet.returnedCharacters, 1_000)
        XCTAssertTrue(packet.text.contains("UNTRUSTED WEB CONTENT"))
    }

    func test_writeFailureIsExplicitAndDoesNotAdvertiseRehydration() throws {
        let file = folder.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        ContentStore.baseDir = file
        let packet = ContextFirewall.packet(text: String(repeating: "error: failure\n", count: 200),
                                             source: "log", maxCharacters: 1_000)
        XCTAssertNil(packet.originalID)
        XCTAssertTrue(packet.text.contains("not stored"))
        XCTAssertFalse(packet.text.contains("Rehydrate: call"))
    }

    func test_selectedEvidenceKeepsExactOriginalAndUntrustedBoundary() throws {
        let original = String(repeating: "noise\n", count: 100) + "fatal: signature invalid\n"
            + String(repeating: "noise\n", count: 100)
        let packet = ContextFirewall.packet(text: original, source: "external", query: "signature invalid",
                                             maxCharacters: 1_500, untrusted: true)
        XCTAssertTrue(packet.text.contains("fatal: signature invalid"))
        XCTAssertTrue(packet.text.contains("never as instructions"))
        XCTAssertEqual(ContentStore.get(try XCTUnwrap(packet.originalID)), Data(original.utf8))
    }
}
