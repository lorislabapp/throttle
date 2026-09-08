import Foundation
@testable import Throttle
import ThrottleShared
import XCTest

@MainActor
final class PeerClientPrivacyTests: XCTestCase {
    private func snapshot(_ byte: UInt8) -> ThrottleMirrorSnapshot {
        MirrorPrivacyFixture.snapshot(secret: Data(repeating: byte, count: 32).base64EncodedString())
    }

    func testStopRejectsCallbacksAlreadyQueuedAndCapturedByOldConnector() async throws {
        let connector = MirrorPeerFake()
        var received: [ThrottleMirrorSnapshot] = []
        let client = PeerClient(makeConnector: { _ in connector }, ingest: { received.append($0) })
        client.syncPairing(from: snapshot(1))
        let oldSnapshot = try XCTUnwrap(connector.onSnapshot)
        let oldConnected = try XCTUnwrap(connector.onConnected)
        oldSnapshot(try snapshot(1).encoded())
        oldConnected(true)
        client.stop()
        oldSnapshot(try snapshot(1).encoded())
        oldConnected(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(client.hasLink)
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(connector.stopCount, 1)
    }

    func testRotationRejectsOldSnapshotAndConnectionStateButAcceptsNewConnector() async throws {
        let first = MirrorPeerFake()
        let second = MirrorPeerFake()
        var received: [ThrottleMirrorSnapshot] = []
        var count = 0
        let client = PeerClient(makeConnector: { _ in
            count += 1
            return count == 1 ? first : second
        }, ingest: { received.append($0) })
        client.syncPairing(from: snapshot(1))
        let oldSnapshot = try XCTUnwrap(first.onSnapshot)
        let oldConnected = try XCTUnwrap(first.onConnected)
        client.syncPairing(from: snapshot(2))
        second.onConnected?(true)
        second.onSnapshot?(try snapshot(2).encoded())
        try await Task.sleep(nanoseconds: 20_000_000)
        oldConnected(false)
        oldSnapshot(try snapshot(1).encoded())
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(client.connected)
        XCTAssertEqual(received, [snapshot(2)])
        XCTAssertEqual(first.stopCount, 1)
        client.stop()
    }

    func testDetachSuppressesQueuedTerminalCallbacksAndOutgoingWrites() async throws {
        let connector = MirrorPeerFake()
        let client = PeerClient(makeConnector: { _ in connector }, ingest: { _ in })
        client.syncPairing(from: snapshot(1))
        connector.onConnected?(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        var output: [[UInt8]] = []
        var resizes = 0
        var invalidated = 0
        client.attachTerminal(tabID: "old", onOutput: { output.append($0) },
                              onResize: { _, _ in resizes += 1 }, onInvalidated: { invalidated += 1 })
        let oldOutput = try XCTUnwrap(connector.onTermOut)
        let oldResize = try XCTUnwrap(connector.onTermResize)
        oldOutput([65])
        oldResize(80, 24)
        client.detachTerminal()
        oldOutput([66])
        client.sendTerminalInput([67])
        client.sendTerminalResize(cols: 80, rows: 24)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(output.isEmpty)
        XCTAssertEqual(resizes, 0)
        XCTAssertEqual(invalidated, 1)
        XCTAssertTrue(connector.inputs.isEmpty)
        XCTAssertEqual(connector.resizeCount, 0)
        client.stop()
    }

    func testReattachmentCannotDeliverPreviousTerminalBytesToEitherView() async throws {
        let connector = MirrorPeerFake()
        let client = PeerClient(makeConnector: { _ in connector }, ingest: { _ in })
        client.syncPairing(from: snapshot(1))
        connector.onConnected?(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        var oldBytes: [[UInt8]] = []
        var newBytes: [[UInt8]] = []
        client.attachTerminal(tabID: "old", onOutput: { oldBytes.append($0) }, onResize: { _, _ in })
        let oldOutput = try XCTUnwrap(connector.onTermOut)
        client.attachTerminal(tabID: "new", onOutput: { newBytes.append($0) }, onResize: { _, _ in })
        oldOutput([65])
        connector.onTermOut?([66])
        client.sendTerminalInput([67])
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(oldBytes.isEmpty)
        XCTAssertEqual(newBytes, [[66]])
        XCTAssertEqual(connector.inputs, [[67]])
        client.stop()
    }

    func testMissingPairingRevokesExistingConnectorAndTerminalImmediately() async throws {
        let connector = MirrorPeerFake()
        let client = PeerClient(makeConnector: { _ in connector }, ingest: { _ in })
        client.syncPairing(from: snapshot(1))
        connector.onConnected?(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        var invalidated = false
        client.attachTerminal(tabID: "old", onOutput: { _ in }, onResize: { _, _ in },
                              onInvalidated: { invalidated = true })
        client.syncPairing(from: MirrorPrivacyFixture.snapshot())
        XCTAssertFalse(client.connected)
        XCTAssertTrue(invalidated)
        XCTAssertEqual(connector.stopCount, 1)
        client.sendTerminalInput([65])
        XCTAssertTrue(connector.inputs.isEmpty)
    }

    func testRetiredViewsDetachCannotDisconnectTheNewAttachment() async throws {
        let connector = MirrorPeerFake()
        let client = PeerClient(makeConnector: { _ in connector }, ingest: { _ in })
        client.syncPairing(from: snapshot(1))
        connector.onConnected?(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        let oldAttachment = try XCTUnwrap(client.attachTerminal(
            tabID: "old", onOutput: { _ in }, onResize: { _, _ in }))
        let currentAttachment = try XCTUnwrap(client.attachTerminal(
            tabID: "new", onOutput: { _ in }, onResize: { _, _ in }))
        XCTAssertNotEqual(oldAttachment, currentAttachment)
        client.detachTerminal(attachment: oldAttachment)
        client.sendTerminalInput([65])
        XCTAssertEqual(connector.inputs, [[65]])
        client.detachTerminal(attachment: currentAttachment)
        client.sendTerminalInput([66])
        XCTAssertEqual(connector.inputs, [[65]])
        client.stop()
    }
}
