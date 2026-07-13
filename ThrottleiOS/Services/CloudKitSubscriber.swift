import Foundation
import CloudKit
import ThrottleShared

/// Fetches the latest mirror snapshot from the user's private CloudKit DB and
/// keeps a silent-push subscription so background pushes refresh it. Read-only.
/// Also owns iCloud account lifecycle: it checks `accountStatus` (so a signed-out
/// state is surfaced, not shown as an opaque error) and scrubs the shared App Group
/// when the iCloud identity changes (privacy — no data bleed between accounts).
@MainActor
@Observable
final class CloudKitSubscriber {
    static let shared = CloudKitSubscriber()
    private let container = CKContainer(identifier: CloudKitSchema.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private init() {}

    private static let subscriptionID = "throttle-snapshot-sub"
    private static let userRecordKey = "ThrottleiCloudUserRecordV1"

    enum Account: Equatable { case unknown, available, signedOut, restricted, error(String) }
    private(set) var account: Account = .unknown

    /// One-shot at launch: verify the account, pull the current snapshot, ensure the
    /// push subscription, and start observing account changes.
    func bootstrap() async {
        NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in await CloudKitSubscriber.shared.handleAccountChange() }
            }
        await refreshAccount()
        guard account == .available else { return }
        await fetchLatest()
        await ensureSubscription()
    }

    private func refreshAccount() async {
        do {
            switch try await container.accountStatus() {
            case .available:            account = .available
            case .noAccount:            account = .signedOut
            case .restricted:           account = .restricted
            case .couldNotDetermine:    account = .unknown
            case .temporarilyUnavailable: account = .unknown
            @unknown default:           account = .unknown
            }
        } catch {
            account = .error(error.localizedDescription)
        }
    }

    /// On an iCloud account switch/sign-out, compare the CloudKit user record id to
    /// the last-seen one; if it changed (or signed out), scrub all mirrored data so
    /// the previous identity's usage/history never shows to a different user.
    private func handleAccountChange() async {
        await refreshAccount()
        let store = UserDefaults(suiteName: MirrorStorage.appGroupID) ?? .standard
        let previous = store.string(forKey: Self.userRecordKey)
        guard account == .available else {
            // Signed out / unavailable → drop everything and forget the identity.
            MirrorStore.shared.scrub()
            store.removeObject(forKey: Self.userRecordKey)
            return
        }
        let current = try? await container.userRecordID().recordName
        if let current, current != previous {
            if previous != nil { MirrorStore.shared.scrub() }  // identity actually changed
            store.set(current, forKey: Self.userRecordKey)
            await fetchLatest()
            await ensureSubscription()
        }
    }

    @discardableResult
    func fetchLatest() async -> Bool {
        let id = CKRecord.ID(recordName: CloudKitSchema.recordName())
        do {
            let record = try await database.record(for: id)
            let snap = try CloudKitRecordMapping.snapshot(from: record)
            MirrorStore.shared.ingest(snap)
            PeerClient.shared.syncPairing(from: snap)
            MirrorStore.shared.lastError = nil
            // Remember the identity that owns this data (first successful fetch).
            if let uid = try? await container.userRecordID().recordName {
                (UserDefaults(suiteName: MirrorStorage.appGroupID) ?? .standard)
                    .set(uid, forKey: Self.userRecordKey)
            }
            return true
        } catch let ck as CKError where ck.code == .unknownItem {
            // Mac hasn't published a snapshot yet — not an error.
            MirrorStore.shared.lastError = nil
            return false
        } catch {
            MirrorStore.shared.lastError = error.localizedDescription
            return false
        }
    }

    private func ensureSubscription() async {
        let sub = CKQuerySubscription(
            recordType: CloudKitSchema.recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push
        sub.notificationInfo = info
        do {
            _ = try await database.save(sub)
        } catch let ck as CKError where ck.code == .serverRejectedRequest {
            // Already registered — the expected idempotent case, ignore.
        } catch {
            // Genuinely couldn't register (e.g. record type not Queryable in
            // Production, or quota): surface it so silent push isn't silently dead.
            MirrorStore.shared.lastError = "Live updates unavailable: \(error.localizedDescription)"
        }
    }
}
