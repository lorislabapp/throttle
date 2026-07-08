import Foundation
import CloudKit
import ThrottleShared

/// Fetches the latest mirror snapshot from the user's private CloudKit DB and
/// keeps a silent-push subscription so background pushes refresh it. Read-only.
@MainActor
final class CloudKitSubscriber {
    static let shared = CloudKitSubscriber()
    private let database = CKContainer(identifier: CloudKitSchema.containerID).privateCloudDatabase
    private init() {}

    private static let subscriptionID = "throttle-snapshot-sub"

    /// One-shot at launch: pull the current snapshot + ensure the push subscription.
    func bootstrap() async {
        await fetchLatest()
        await ensureSubscription()
    }

    func fetchLatest() async {
        let id = CKRecord.ID(recordName: CloudKitSchema.recordName())
        do {
            let record = try await database.record(for: id)
            let snap = try CloudKitRecordMapping.snapshot(from: record)
            MirrorStore.shared.ingest(snap)
            MirrorStore.shared.lastError = nil
        } catch let ck as CKError where ck.code == .unknownItem {
            // Mac hasn't published a snapshot yet — not an error.
        } catch {
            MirrorStore.shared.lastError = error.localizedDescription
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
        } catch {
            // Already registered or transient — safe to ignore; fetchLatest still works.
        }
    }
}
