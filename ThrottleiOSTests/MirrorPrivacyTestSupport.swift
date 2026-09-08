import CloudKit
import Foundation
@testable import Throttle
import ThrottlePeer
import ThrottleShared
import XCTest

actor MirrorTestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entryWaiters.forEach { $0.resume() }
            entryWaiters = []
        }
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
final class MirrorCloudFake: MirrorCloudBackend {
    var status: CKAccountStatus = .available
    var identity = "account-A"
    var snapshot: ThrottleMirrorSnapshot?
    var snapshotCalls = 0
    var identityCalls = 0
    var identityHandler: (() async throws -> String)?
    var snapshotHandler: (() async throws -> ThrottleMirrorSnapshot?)?
    var subscriptionHandler: (() async throws -> Void)?

    func accountStatus() async throws -> CKAccountStatus { status }
    func userRecordName() async throws -> String {
        identityCalls += 1
        if let identityHandler { return try await identityHandler() }
        return identity
    }
    func latestSnapshot() async throws -> ThrottleMirrorSnapshot? {
        snapshotCalls += 1
        if let snapshotHandler { return try await snapshotHandler() }
        return snapshot
    }
    func ensureSubscription() async throws { try await subscriptionHandler?() }
}

@MainActor
final class MirrorPeerFake: MirrorPeerConnecting {
    var onSnapshot: (@Sendable (Data) -> Void)?
    var onConnected: (@Sendable (Bool) -> Void)?
    var onTermOut: (@Sendable ([UInt8]) -> Void)?
    var onTermResize: (@Sendable (Int, Int) -> Void)?
    var stopCount = 0
    var attachments: [String] = []
    var inputs: [[UInt8]] = []
    var resizeCount = 0
    func start() {}
    func stop() { stopCount += 1 }
    func attachTerminal(sessionId: String) { attachments.append(sessionId) }
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
    func sendResize(cols: Int, rows: Int) { resizeCount += 1 }
    func detachTerminal() {}
}

@MainActor
enum MirrorPrivacyFixture {
    static func snapshot(_ second: TimeInterval = 1, secret: String? = nil) -> ThrottleMirrorSnapshot {
        let window = WindowMirror(utilization: 20, resetsAt: nil)
        return .init(publishedAt: Date(timeIntervalSince1970: second), deviceName: "Test Mac",
                     fiveHour: window, sevenDay: window, sevenDaySonnet: window,
                     weeklyTokens: 100, weeklyCostEUR: 1, savedTokensThisWeek: 0,
                     sessionCount: 0, tabs: [], peerPairingSecret: secret)
    }

    static func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "Throttle-MirrorPrivacy-" + UUID().uuidString))
    }

    static func store(_ defaults: UserDefaults, onScrub: @escaping @MainActor () -> Void = {}) -> MirrorStore {
        MirrorStore(defaults: defaults, reloadWidgets: {}, didIngest: { _ in }, didScrub: onScrub)
    }

    static func seedCache(_ defaults: UserDefaults, owner: String? = "account-A") throws {
        defaults.set(try snapshot().encoded(), forKey: MirrorStorage.latestSnapshotKey)
        defaults.set(try JSONEncoder.iso.encode([snapshot()]), forKey: MirrorStore.historyKey)
        defaults.set(owner, forKey: CloudKitSubscriber.userRecordKey)
    }
}
