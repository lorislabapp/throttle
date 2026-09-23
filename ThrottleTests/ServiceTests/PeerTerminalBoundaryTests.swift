import Foundation
import Security
@testable import Throttle
import ThrottlePeer
import ThrottleShared
import XCTest

/// Native production boundaries with effect injection: no listener, PTY, model,
/// shared singleton, real Keychain or UserDefaults is touched by these fixtures.
@MainActor
final class PeerTerminalBoundaryTests: XCTestCase {
    @MainActor
    private final class Terminal: PeerBridgeTerminal {
        var onOutputBytes: (@MainActor ([UInt8]) -> Void)?
        var peerGeometry = (cols: 100, rows: 30)
        var inputs: [[UInt8]] = []
        func injectRemoteInput(_ bytes: [UInt8]) { inputs.append(bytes) }
    }

    private struct Resize {
        let cols: Int
        let rows: Int
        let client: PeerClientID
    }

    @MainActor
    private final class Harness {
        var permitted = true
        var terminals: [UUID: Terminal] = [:]
        var outputs: [([UInt8], PeerClientID)] = []
        var sizes: [Resize] = []
        lazy var bridge = PeerTerminalBridge(
            permitsControl: { [weak self] in self?.permitted ?? false },
            resolveTerminal: { [weak self] in self?.terminals[$0] },
            sendOutput: { [weak self] in self?.outputs.append(($0, $1)) },
            sendResize: { [weak self] in self?.sizes.append(Resize(cols: $0, rows: $1, client: $2)) }
        )
    }

    private let client = PeerClientID(raw: 1)
    private let canary: [UInt8] = Array("synthetic input".utf8)

    func testRevokedTicketQueuedBeforeMainActorDeliveryCannotAttachOrSend() async throws {
        let harness = Harness()
        let session = UUID()
        let terminal = Terminal()
        harness.terminals[session] = terminal
        let admission = PeerControlAdmission()
        let listener = admission.start(controlEnabled: true)
        let ticket = try XCTUnwrap(admission.ticket(for: listener))
        let queued = Task { @MainActor in
            PeerTransport.deliverControl((.attach(sessionId: session.uuidString), client),
                ticket: ticket, admission: admission, controlEnabled: harness.permitted,
                handle: harness.bridge.handle)
        }
        // No suspension occurred before revocation; delivery is queued on this actor.
        admission.setControlEnabled(false)
        admission.setControlEnabled(true)
        await queued.value
        XCTAssertNil(terminal.onOutputBytes)
        XCTAssertTrue(harness.outputs.isEmpty)
        XCTAssertTrue(harness.sizes.isEmpty)

        let fresh = try XCTUnwrap(admission.ticket(for: listener))
        PeerTransport.deliverControl((.attach(sessionId: session.uuidString), client),
            ticket: fresh, admission: admission, controlEnabled: true, handle: harness.bridge.handle)
        XCTAssertNotNil(terminal.onOutputBytes)
        XCTAssertEqual(harness.sizes.count, 1)
    }

    func testCurrentTicketCannotBypassControlSettingOffAtDelivery() throws {
        let harness = Harness()
        let session = UUID()
        let terminal = Terminal()
        harness.terminals[session] = terminal
        let admission = PeerControlAdmission()
        let listener = admission.start(controlEnabled: true)
        let ticket = try XCTUnwrap(admission.ticket(for: listener))
        PeerTransport.deliverControl((.attach(sessionId: session.uuidString), client),
            ticket: ticket, admission: admission, controlEnabled: false, handle: harness.bridge.handle)
        XCTAssertNil(terminal.onOutputBytes)
        XCTAssertTrue(harness.sizes.isEmpty)
        XCTAssertTrue(harness.outputs.isEmpty)
    }

    func testStoppedListenerCannotDeliverQueuedInputAfterRestart() async throws {
        let harness = Harness()
        let session = UUID()
        let terminal = Terminal()
        harness.terminals[session] = terminal
        harness.bridge.handle(.attach(sessionId: session.uuidString), from: client)
        let admission = PeerControlAdmission()
        let listener = admission.start(controlEnabled: true)
        let old = try XCTUnwrap(admission.ticket(for: listener))
        let queued = Task { @MainActor in
            PeerTransport.deliverControl((.input(canary), client),
                ticket: old, admission: admission, controlEnabled: true, handle: harness.bridge.handle)
        }
        admission.stop()
        _ = admission.start(controlEnabled: true)
        await queued.value
        XCTAssertTrue(terminal.inputs.isEmpty)
    }

    func testBridgeDeniesDirectCallsWhenPermissionIsOff() {
        let harness = Harness()
        harness.permitted = false
        let session = UUID()
        let terminal = Terminal()
        harness.terminals[session] = terminal
        harness.bridge.handle(.attach(sessionId: session.uuidString), from: client)
        harness.bridge.handle(.input(canary), from: client)
        XCTAssertNil(terminal.onOutputBytes)
        XCTAssertTrue(terminal.inputs.isEmpty)
        XCTAssertTrue(harness.sizes.isEmpty)
        XCTAssertTrue(harness.outputs.isEmpty)
    }

    func testRevocationRemovesTapAndStaleCallbackCannotSendOrInput() throws {
        let harness = Harness()
        let session = UUID()
        let terminal = Terminal()
        harness.terminals[session] = terminal
        harness.bridge.handle(.attach(sessionId: session.uuidString), from: client)
        let queuedOutput = try XCTUnwrap(terminal.onOutputBytes)
        harness.permitted = false
        harness.bridge.handle(.input(canary), from: client)
        queuedOutput(canary)
        XCTAssertNil(terminal.onOutputBytes)
        XCTAssertTrue(terminal.inputs.isEmpty)
        XCTAssertTrue(harness.outputs.isEmpty)
        harness.permitted = true
        harness.bridge.handle(.input(canary), from: client)
        XCTAssertTrue(terminal.inputs.isEmpty, "New consent must not restore an old attachment")
    }

    func testReattachmentStopsOldTapAndOnlyAddressesNewSession() {
        let harness = Harness()
        let first = UUID(), second = UUID()
        let oldTerminal = Terminal(), newTerminal = Terminal()
        harness.terminals = [first: oldTerminal, second: newTerminal]
        harness.bridge.handle(.attach(sessionId: first.uuidString), from: client)
        harness.bridge.handle(.attach(sessionId: second.uuidString), from: client)
        harness.bridge.handle(.input(canary), from: client)
        XCTAssertNil(oldTerminal.onOutputBytes)
        XCTAssertTrue(oldTerminal.inputs.isEmpty)
        XCTAssertEqual(newTerminal.inputs, [canary])
        newTerminal.onOutputBytes?(canary)
        XCTAssertEqual(harness.outputs.map { $0.1 }, [client])
        harness.bridge.handle(.detach, from: client)
        XCTAssertNil(newTerminal.onOutputBytes)
    }

    func testUnknownSessionAndInputWithoutAttachmentHaveNoEffects() {
        let harness = Harness()
        harness.bridge.handle(.attach(sessionId: UUID().uuidString), from: client)
        harness.bridge.handle(.attach(sessionId: "invalid"), from: client)
        harness.bridge.handle(.input(canary), from: client)
        XCTAssertTrue(harness.terminals.isEmpty)
        XCTAssertTrue(harness.outputs.isEmpty)
        XCTAssertTrue(harness.sizes.isEmpty)
    }

    func testUnavailablePairingDoesNotReadLegacyWriteGenerateOrPublishIdentity() throws {
        let pairing = try XCTUnwrap(PeerPairingSecret(raw: Data(repeating: 0x31, count: 32)))
        var effects = 0
        let transport = PeerTransport(credential: .unavailable(errSecInteractionNotAllowed),
            legacy: { effects += 1; return pairing.base64 },
            persist: { _ in effects += 1; return true },
            removeLegacy: { effects += 1 }, generate: { effects += 1; return pairing })
        XCTAssertEqual(effects, 0)
        XCTAssertNil(transport.pairingSecretBase64)
        XCTAssertNotNil(transport.pairingPersistenceError)
    }

    func testMalformedPersistedPairingIsNotReplacedAutomatically() throws {
        let pairing = try XCTUnwrap(PeerPairingSecret(raw: Data(repeating: 0x31, count: 32)))
        var effects = 0
        let transport = PeerTransport(credential: .found("not-base64"),
            legacy: { effects += 1; return nil }, persist: { _ in effects += 1; return true },
            removeLegacy: { effects += 1 }, generate: { effects += 1; return pairing })
        XCTAssertEqual(effects, 0)
        XCTAssertNil(transport.pairingSecretBase64)
        XCTAssertNotNil(transport.pairingPersistenceError)
    }

    func testFailedLegacyPersistencePreservesCopyAndWithholdsPairing() throws {
        let pairing = try XCTUnwrap(PeerPairingSecret(raw: Data(repeating: 0x31, count: 32)))
        var events: [String] = []
        let transport = PeerTransport(credential: .missing, legacy: { pairing.base64 },
            persist: { _ in events.append("persist"); return false },
            removeLegacy: { events.append("remove") },
            generate: { XCTFail("Unexpected generation"); return pairing })
        XCTAssertEqual(events, ["persist"])
        XCTAssertNil(transport.pairingSecretBase64)
        XCTAssertNotNil(transport.pairingPersistenceError)
    }

    func testSuccessfulLegacyPersistencePrecedesRemoval() throws {
        let pairing = try XCTUnwrap(PeerPairingSecret(raw: Data(repeating: 0x31, count: 32)))
        var events: [String] = []
        let transport = PeerTransport(credential: .missing, legacy: { pairing.base64 },
            persist: { value in
                XCTAssertEqual(value, pairing.base64)
                events.append("persist")
                return true
            }, removeLegacy: { events.append("remove") },
            generate: { XCTFail("Unexpected generation"); return pairing })
        XCTAssertEqual(events, ["persist", "remove"])
        XCTAssertEqual(transport.pairingSecretBase64, pairing.base64)
        XCTAssertNil(transport.pairingPersistenceError)
    }

    func testFailedFreshPersistenceNeverPublishesEphemeralPairing() throws {
        let pairing = try XCTUnwrap(PeerPairingSecret(raw: Data(repeating: 0x31, count: 32)))
        var events: [String] = []
        let transport = PeerTransport(credential: .missing, legacy: { nil },
            persist: { _ in events.append("persist"); return false },
            removeLegacy: { events.append("remove") },
            generate: { events.append("generate"); return pairing })
        XCTAssertEqual(events, ["generate", "persist"])
        XCTAssertNil(transport.pairingSecretBase64)
        XCTAssertNotNil(transport.pairingPersistenceError)
    }
}
