import XCTest
@testable import Throttle

final class SessionFileParserTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "jsonl") else {
            throw XCTSkip("Fixture \(name).jsonl missing from test bundle")
        }
        return url
    }

    func test_parsesSampleSessionFromOffsetZero() throws {
        let url = try fixtureURL("sample-session")
        let result = try SessionFileParser.parse(url: url, fromByteOffset: 0)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events[0].model, "claude-opus-4-7")
        XCTAssertEqual(result.events[1].model, "claude-sonnet-4-6")
        XCTAssertGreaterThan(result.bytesRead, 0)
    }

    func test_returnsEmptyForEmptyFile() throws {
        let url = try fixtureURL("empty-session")
        let result = try SessionFileParser.parse(url: url, fromByteOffset: 0)
        XCTAssertEqual(result.events.count, 0)
        XCTAssertEqual(result.bytesRead, 0)
    }

    func test_resumesFromOffset() throws {
        let url = try fixtureURL("sample-session")
        let firstPass = try SessionFileParser.parse(url: url, fromByteOffset: 0)
        let secondPass = try SessionFileParser.parse(url: url, fromByteOffset: firstPass.bytesRead)
        XCTAssertEqual(secondPass.events.count, 0)
    }
}
