import Foundation
import ThrottlePeerProtocol
import XCTest

final class PeerMessageConformanceTests: XCTestCase {
    // Literal fixtures describe the deployed framing, independently of encoded().
    private let snapshot = Data([
        0x02, 0x01, 0x23, 0x45, 0x67,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x00, 0x00, 0x00, 0x03, 0x00, 0x80, 0xff
    ])
    private let heartbeat = Data([
        0x03, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07,
        0x00, 0x00, 0x00, 0x00
    ])

    func testEncoderMatchesGoldenBytes() {
        let message = PeerMessage(
            kind: .snapshot, seq: 0x01234567,
            timestampMillis: 0x0123456789abcdef, payload: Data([0x00, 0x80, 0xff])
        )
        XCTAssertEqual(message.encoded(), snapshot)
        XCTAssertEqual(PeerMessage(kind: .heartbeat, seq: 1, timestampMillis: 7).encoded(), heartbeat)
    }

    func testDecoderReadsGoldenBytes() throws {
        let decoded = try XCTUnwrap(PeerMessage.decode(from: snapshot))
        XCTAssertEqual(decoded.consumed, 20)
        XCTAssertEqual(decoded.message.kind, .snapshot)
        XCTAssertEqual(decoded.message.seq, 0x01234567)
        XCTAssertEqual(decoded.message.timestampMillis, 0x0123456789abcdef)
        XCTAssertEqual(decoded.message.payload, Data([0x00, 0x80, 0xff]))
    }

    func testEveryKindKeepsItsAssignedWireValue() throws {
        let kinds: [(UInt8, PeerMessage.Kind)] = [
            (1, .hello), (2, .snapshot), (3, .heartbeat), (4, .termAttach),
            (5, .termOut), (6, .termIn), (7, .termResize), (8, .termDetach)
        ]
        for (raw, kind) in kinds {
            let wire = Data([raw] + [UInt8](repeating: 0, count: 16))
            XCTAssertEqual(try PeerMessage.decode(from: wire)?.message.kind, kind)
            XCTAssertEqual(PeerMessage(kind: kind, seq: 0, timestampMillis: 0).encoded(), wire)
        }
    }

    func testEveryTruncatedPrefixNeedsMoreBytes() throws {
        for count in 0..<snapshot.count {
            XCTAssertNil(try PeerMessage.decode(from: snapshot.prefix(count)), "prefix \(count)")
        }
    }

    func testConcatenatedFramesConsumeOnlyOneAtATime() throws {
        var stream = snapshot + heartbeat
        let first = try XCTUnwrap(PeerMessage.decode(from: stream))
        XCTAssertEqual(first.consumed, snapshot.count)
        stream.removeFirst(first.consumed)
        let second = try XCTUnwrap(PeerMessage.decode(from: stream))
        XCTAssertEqual(second.consumed, heartbeat.count)
        XCTAssertEqual(second.message, PeerMessage(kind: .heartbeat, seq: 1, timestampMillis: 7))
    }

    func testDecodesSliceWithNonzeroStartIndex() throws {
        let storage = Data([0xaa, 0xbb, 0xcc]) + snapshot
        let slice = storage.dropFirst(3)
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(try PeerMessage.decode(from: slice)?.message.payload, Data([0x00, 0x80, 0xff]))
        XCTAssertEqual(try PeerMessage.decode(from: slice)?.consumed, 20)
    }

    func testMaximumPayloadIsAccepted() throws {
        let header = Data([
            2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x40, 0x00, 0x00
        ])
        XCTAssertEqual(PeerMessage.maxPayload, 4_194_304)
        XCTAssertNil(try PeerMessage.decode(from: header))
        let payload = Data(repeating: 0xa5, count: 4_194_304)
        let decoded = try XCTUnwrap(PeerMessage.decode(from: header + payload))
        XCTAssertEqual(decoded.message.payload, payload)
        XCTAssertEqual(decoded.consumed, 17 + 4_194_304)
    }

    func testOversizedLengthsAreRejectedBeforePayloadArrives() {
        for (length, count) in [
            ([UInt8](arrayLiteral: 0x00, 0x40, 0x00, 0x01), 4_194_305),
            ([UInt8](repeating: 0xff, count: 4), 4_294_967_295)
        ] {
            let header = Data([2] + [UInt8](repeating: 0, count: 12) + length)
            XCTAssertThrowsError(try PeerMessage.decode(from: header)) { error in
                XCTAssertEqual(error as? PeerMessage.FramingError, .payloadTooLarge(count))
            }
        }
    }

    func testUnknownKindsAreRejected() {
        for kind: UInt8 in [0, 9, 255] {
            let wire = Data([kind] + [UInt8](repeating: 0, count: 16))
            XCTAssertThrowsError(try PeerMessage.decode(from: wire)) { error in
                XCTAssertEqual(error as? PeerMessage.FramingError, .unknownKind(kind))
            }
        }
    }

    func testUnknownKindWithIncompletePayloadPreservesStreamingBehavior() throws {
        var wire = snapshot
        wire[0] = 255
        XCTAssertNil(try PeerMessage.decode(from: wire.dropLast()))
        XCTAssertThrowsError(try PeerMessage.decode(from: wire)) { error in
            XCTAssertEqual(error as? PeerMessage.FramingError, .unknownKind(255))
        }
    }

    func testUnsignedMaximumSequenceAndTimestamp() throws {
        let wire = Data([3] + [UInt8](repeating: 0xff, count: 12) + [0, 0, 0, 0])
        let message = PeerMessage(kind: .heartbeat, seq: .max, timestampMillis: .max)
        XCTAssertEqual(message.encoded(), wire)
        XCTAssertEqual(try PeerMessage.decode(from: wire)?.message, message)
    }
}
