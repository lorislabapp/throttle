import Foundation
import ThrottlePeerProtocol
import XCTest

/// Runs the language-neutral vectors in `Conformance/peer-message-vectors.json`
/// against this implementation. The vectors are what another implementation is
/// held to; running them here keeps the data and the Swift code from drifting.
final class PeerMessageVectorTests: XCTestCase {

    private struct Document: Decodable {
        let formatVersion: Int
        let maxPayloadBytes: Int
        let kinds: [String: String]
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let type: String
        let wireHex: String?
        let headerHex: String?
        let payloadRepeat: Repeat?
        let expect: Expectation?
    }

    private struct Repeat: Decodable {
        let byteHex: String
        let count: Int
    }

    /// One shape for every vector type; each type reads only what it needs.
    private enum Expectation: Decodable {
        case frame(FrameExpect)
        case reject(RejectExpect)
        case stream([FrameExpect])

        init(from decoder: Decoder) throws {
            if let list = try? [FrameExpect](from: decoder) { self = .stream(list); return }
            if let reject = try? RejectExpect(from: decoder) { self = .reject(reject); return }
            self = .frame(try FrameExpect(from: decoder))
        }
    }

    private struct FrameExpect: Decodable {
        let kind: String
        let seq: UInt32?
        let timestampMillis: UInt64?
        let payloadHex: String?
        let consumed: Int
    }

    private struct RejectExpect: Decodable {
        let error: String
        let value: Int
    }

    private func load() throws -> Document {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Conformance/peer-message-vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Document.self, from: Data(contentsOf: url))
    }

    private func bytes(_ hex: String) throws -> Data {
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16), "bad hex in vector"))
            index = next
        }
        return out
    }

    private func kind(_ name: String, in document: Document) throws -> PeerMessage.Kind {
        let raw = try XCTUnwrap(document.kinds.first { $0.value == name }?.key, "unknown kind name \(name)")
        return try XCTUnwrap(PeerMessage.Kind(rawValue: XCTUnwrap(UInt8(raw))))
    }

    func testTheVectorFileDescribesThisImplementation() throws {
        let document = try load()
        XCTAssertEqual(document.formatVersion, 1)
        XCTAssertEqual(document.maxPayloadBytes, PeerMessage.maxPayload)
        for (raw, name) in document.kinds {
            let value = try XCTUnwrap(UInt8(raw))
            XCTAssertNotNil(PeerMessage.Kind(rawValue: value), "kind \(raw) \(name) is not implemented")
        }
        XCTAssertGreaterThanOrEqual(document.vectors.count, 20)
    }

    func testEveryVectorHoldsForThisImplementation() throws {
        let document = try load()
        for vector in document.vectors {
            switch vector.type {
            case "frame":
                try checkFrame(vector, document: document)
            case "frame_generated":
                try checkGenerated(vector, document: document)
            case "incomplete":
                let wire = try bytes(XCTUnwrap(vector.wireHex))
                XCTAssertNil(try PeerMessage.decode(from: wire), "\(vector.name): must wait for more bytes")
            case "reject":
                try checkReject(vector)
            case "stream":
                try checkStream(vector, document: document)
            default:
                XCTFail("\(vector.name): unknown vector type \(vector.type) — the runner must not skip it")
            }
        }
    }

    private func checkFrame(_ vector: Vector, document: Document) throws {
        let wire = try bytes(XCTUnwrap(vector.wireHex))
        guard case .frame(let expect) = try XCTUnwrap(vector.expect) else {
            return XCTFail("\(vector.name): frame without a frame expectation")
        }
        let decoded = try XCTUnwrap(PeerMessage.decode(from: wire), vector.name)
        let expected = PeerMessage(
            kind: try kind(expect.kind, in: document), seq: try XCTUnwrap(expect.seq),
            timestampMillis: try XCTUnwrap(expect.timestampMillis),
            payload: try bytes(XCTUnwrap(expect.payloadHex))
        )
        XCTAssertEqual(decoded.message, expected, vector.name)
        XCTAssertEqual(decoded.consumed, expect.consumed, vector.name)
        XCTAssertEqual(expected.encoded(), wire, "\(vector.name): encoding must reproduce the wire bytes")
    }

    private func checkGenerated(_ vector: Vector, document: Document) throws {
        let repeatSpec = try XCTUnwrap(vector.payloadRepeat)
        let byte = try XCTUnwrap(UInt8(repeatSpec.byteHex, radix: 16))
        let wire = try bytes(XCTUnwrap(vector.headerHex)) + Data(repeating: byte, count: repeatSpec.count)
        guard case .frame(let expect) = try XCTUnwrap(vector.expect) else {
            return XCTFail("\(vector.name): generated frame without a frame expectation")
        }
        let decoded = try XCTUnwrap(PeerMessage.decode(from: wire), vector.name)
        XCTAssertEqual(decoded.message.kind, try kind(expect.kind, in: document), vector.name)
        XCTAssertEqual(decoded.message.payload.count, repeatSpec.count, vector.name)
        XCTAssertEqual(decoded.consumed, expect.consumed, vector.name)
    }

    private func checkReject(_ vector: Vector) throws {
        let wire = try bytes(XCTUnwrap(vector.wireHex))
        guard case .reject(let expect) = try XCTUnwrap(vector.expect) else {
            return XCTFail("\(vector.name): reject without an error expectation")
        }
        let wanted: PeerMessage.FramingError
        switch expect.error {
        case "unknown_kind": wanted = .unknownKind(UInt8(expect.value))
        case "payload_too_large": wanted = .payloadTooLarge(expect.value)
        default: return XCTFail("\(vector.name): unknown error name \(expect.error)")
        }
        XCTAssertThrowsError(try PeerMessage.decode(from: wire), vector.name) { error in
            XCTAssertEqual(error as? PeerMessage.FramingError, wanted, vector.name)
        }
    }

    private func checkStream(_ vector: Vector, document: Document) throws {
        var wire = try bytes(XCTUnwrap(vector.wireHex))
        guard case .stream(let frames) = try XCTUnwrap(vector.expect) else {
            return XCTFail("\(vector.name): stream without a list of frames")
        }
        for expect in frames {
            let decoded = try XCTUnwrap(PeerMessage.decode(from: wire), vector.name)
            XCTAssertEqual(decoded.message.kind, try kind(expect.kind, in: document), vector.name)
            XCTAssertEqual(decoded.consumed, expect.consumed, vector.name)
            wire.removeFirst(decoded.consumed)
        }
        XCTAssertTrue(wire.isEmpty, "\(vector.name): bytes left over after the expected frames")
    }
}
