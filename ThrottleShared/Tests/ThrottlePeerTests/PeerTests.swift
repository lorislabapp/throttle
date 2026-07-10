import XCTest
import CryptoKit
@testable import ThrottlePeer

final class PeerMessageTests: XCTestCase {

    func testSnapshotRoundTrip() throws {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let msg = PeerMessage(kind: .snapshot, seq: 42, timestampMillis: 1_700_000_000_000, payload: payload)
        let wire = msg.encoded()
        XCTAssertEqual(wire.count, PeerMessage.headerSize + payload.count)

        let decoded = try PeerMessage.decode(from: wire)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.consumed, wire.count)
        XCTAssertEqual(decoded?.message, msg)
    }

    func testHeartbeatEmptyPayload() throws {
        let msg = PeerMessage(kind: .heartbeat, seq: 1, timestampMillis: 7)
        let decoded = try PeerMessage.decode(from: msg.encoded())
        XCTAssertEqual(decoded?.message.kind, .heartbeat)
        XCTAssertEqual(decoded?.message.payload.count, 0)
    }

    func testIncompleteBufferReturnsNil() throws {
        let msg = PeerMessage(kind: .snapshot, seq: 1, timestampMillis: 0, payload: Data([1, 2, 3, 4, 5]))
        let wire = msg.encoded()
        // One byte short of a full frame → not enough data yet.
        XCTAssertNil(try PeerMessage.decode(from: wire.prefix(wire.count - 1)))
        // Header not even complete.
        XCTAssertNil(try PeerMessage.decode(from: wire.prefix(3)))
    }

    func testTwoFramesConsumeExactly() throws {
        let a = PeerMessage(kind: .hello, seq: 1, timestampMillis: 10, payload: Data("mac".utf8))
        let b = PeerMessage(kind: .snapshot, seq: 2, timestampMillis: 20, payload: Data("xy".utf8))
        var stream = a.encoded() + b.encoded()

        let first = try PeerMessage.decode(from: stream)
        XCTAssertEqual(first?.message, a)
        stream.removeFirst(first!.consumed)

        let second = try PeerMessage.decode(from: stream)
        XCTAssertEqual(second?.message, b)
        stream.removeFirst(second!.consumed)
        XCTAssertTrue(stream.isEmpty)
    }

    func testUnknownKindThrows() {
        var wire = PeerMessage(kind: .hello, seq: 0, timestampMillis: 0).encoded()
        wire[wire.startIndex] = 99   // corrupt the kind byte
        XCTAssertThrowsError(try PeerMessage.decode(from: wire)) { error in
            XCTAssertEqual(error as? PeerMessage.FramingError, .unknownKind(99))
        }
    }

    func testTerminalFramesRoundTrip() throws {
        let out = PeerMessage(kind: .termOut, seq: 5, timestampMillis: 1, payload: Data([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(try PeerMessage.decode(from: out.encoded())?.message, out)
        let attach = PeerMessage(kind: .termAttach, seq: 1, timestampMillis: 0, payload: Data("abc123".utf8))
        XCTAssertEqual(try PeerMessage.decode(from: attach.encoded())?.message.kind, .termAttach)
    }

    func testResizePayloadRoundTrip() {
        let p = PeerTerminal.resizePayload(cols: 120, rows: 40)
        XCTAssertEqual(p.count, 4)
        let d = PeerTerminal.decodeResize(p)
        XCTAssertEqual(d?.cols, 120)
        XCTAssertEqual(d?.rows, 40)
        XCTAssertNil(PeerTerminal.decodeResize(Data([1, 2, 3])))
    }

    func testDecodeFromSliceWithOffset() throws {
        // A buffer whose startIndex != 0 (common after removeFirst) must still decode.
        let msg = PeerMessage(kind: .snapshot, seq: 9, timestampMillis: 5, payload: Data("abc".utf8))
        var stream = Data([0xFF, 0xFF]) + msg.encoded()
        stream.removeFirst(2)                       // now a slice with offset 2
        let decoded = try PeerMessage.decode(from: stream)
        XCTAssertEqual(decoded?.message, msg)
    }
}

final class PeerPairingTests: XCTestCase {

    func testPSKIsDeterministicForSameSecret() {
        let secret = PeerPairingSecret.generate()
        let a = PeerPairing.preSharedKeyData(from: secret)
        let b = PeerPairing.preSharedKeyData(from: secret)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testDifferentSecretsGiveDifferentPSK() {
        let s1 = PeerPairingSecret.generate()
        let s2 = PeerPairingSecret.generate()
        XCTAssertNotEqual(PeerPairing.preSharedKeyData(from: s1),
                          PeerPairing.preSharedKeyData(from: s2))
    }

    func testSecretBase64RoundTrip() {
        let secret = PeerPairingSecret.generate()
        let restored = PeerPairingSecret(base64: secret.base64)
        XCTAssertEqual(restored, secret)
    }

    func testSecretRejectsWrongLength() {
        XCTAssertNil(PeerPairingSecret(raw: Data(repeating: 0, count: 16)))
        XCTAssertNotNil(PeerPairingSecret(raw: Data(repeating: 0, count: 32)))
    }
}
