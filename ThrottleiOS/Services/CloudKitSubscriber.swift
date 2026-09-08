import CloudKit
import Foundation
import OSLog
import ThrottleShared

/// The identity that authorizes a snapshot must survive every CloudKit await.
/// A generation also rejects replies already in flight when an account changes.
@MainActor
@Observable
final class CloudKitSubscriber {
    static let shared = CloudKitSubscriber()
    static let userRecordKey = "ThrottleiCloudUserRecordV1"
    private static let log = Logger(subsystem: "com.lorislab.throttle.ios", category: "CloudKit")

    enum Account: Equatable { case unknown, available, signedOut, restricted, error(String) }
    private(set) var account: Account = .unknown
    private(set) var pushAvailable = false

    private let backend: any MirrorCloudBackend
    private let defaults: UserDefaults
    private let mirror: MirrorStore
    private let pair: (ThrottleMirrorSnapshot) -> Void
    private let notifications: NotificationCenter?
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var verifiedIdentity: String?

    init(backend: any MirrorCloudBackend = SystemMirrorCloudBackend(),
         defaults: UserDefaults = CompanionRuntime.defaults,
         mirror: MirrorStore = .shared,
         pair: @escaping (ThrottleMirrorSnapshot) -> Void = { PeerClient.shared.syncPairing(from: $0) },
         notifications: NotificationCenter? = CompanionRuntime.isTesting ? nil : .default) {
        self.backend = backend
        self.defaults = defaults
        self.mirror = mirror
        self.pair = pair
        self.notifications = notifications
    }

    func bootstrap() async {
        if observer == nil, let notifications {
            observer = notifications.addObserver(
                forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                // The observer runs on the main queue. Revoke synchronously before
                // scheduling a refresh: queued old responses must already be stale.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.accountDidChange()
                    Task { [weak self] in await self?.refreshWithSubscription() }
                }
            }
        }
        await refreshWithSubscription()
    }

    private func refreshWithSubscription() async {
        _ = await fetchLatest()
        guard account == .available, let identity = verifiedIdentity else { return }
        await ensureSubscription(identity: identity, generation: generation)
    }

    /// May be called before starting any asynchronous reconciliation.
    func accountDidChange() {
        generation &+= 1
        verifiedIdentity = nil
        account = .unknown
        pushAvailable = false
        mirror.scrub()
        defaults.removeObject(forKey: Self.userRecordKey)
    }

    private func isCurrent(_ token: UInt64) -> Bool { token == generation && !Task.isCancelled }

    private func identity(generation token: UInt64) async -> String? {
        do {
            let status = try await backend.accountStatus()
            guard isCurrent(token) else { return nil }
            guard status == .available else {
                accountDidChange()
                switch status {
                case .noAccount: account = .signedOut
                case .restricted: account = .restricted
                default: account = .unknown
                }
                return nil
            }
            let identity = try await backend.userRecordName()
            guard isCurrent(token) else { return nil }
            guard !identity.isEmpty else { throw MirrorCloudError.missingIdentity }
            return identity
        } catch {
            guard isCurrent(token) else { return nil }
            accountDidChange()
            account = .error(error.localizedDescription)
            return nil
        }
    }

    private func verify(_ expected: String, generation token: UInt64) async -> Bool {
        guard let current = await identity(generation: token) else { return false }
        guard current == expected else {
            accountDidChange()
            return false
        }
        return isCurrent(token)
    }

    @discardableResult
    func fetchLatest() async -> Bool {
        generation &+= 1
        let token = generation
        guard let current = await identity(generation: token) else { return false }
        let storedOwner = defaults.string(forKey: Self.userRecordKey)
        let activeOwnerChanged = verifiedIdentity != nil && verifiedIdentity != current
        if storedOwner != current || activeOwnerChanged {
            // This also rejects an unowned legacy cache: no arbitrary migration to
            // the first account encountered after upgrading or switching accounts.
            mirror.scrub()
            pushAvailable = false
        } else if verifiedIdentity == nil {
            mirror.restoreVerifiedCache()
        }
        defaults.set(current, forKey: Self.userRecordKey)
        verifiedIdentity = current
        account = .available

        let result: Result<ThrottleMirrorSnapshot?, Error>
        do { result = .success(try await backend.latestSnapshot()) } catch { result = .failure(error) }
        guard isCurrent(token), await verify(current, generation: token) else { return false }
        switch result {
        case .success(let snapshot):
            mirror.lastError = nil
            guard let snapshot else { return false }
            mirror.ingest(snapshot)
            pair(snapshot)
            return true
        case .failure(let error):
            mirror.lastError = error.localizedDescription
            return false
        }
    }

    private func ensureSubscription(identity: String, generation token: UInt64) async {
        guard isCurrent(token) else { return }
        let succeeded: Bool
        do { try await backend.ensureSubscription(); succeeded = true } catch {
            succeeded = false
            Self.log.info("silent-push subscription unavailable: \(error.localizedDescription, privacy: .public)")
        }
        guard isCurrent(token), await verify(identity, generation: token) else { return }
        pushAvailable = succeeded
    }
}
