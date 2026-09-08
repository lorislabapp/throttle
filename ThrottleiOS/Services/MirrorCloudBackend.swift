import CloudKit
import Foundation
import ThrottleShared

@MainActor
protocol MirrorCloudBackend {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordName() async throws -> String
    func latestSnapshot() async throws -> ThrottleMirrorSnapshot?
    func ensureSubscription() async throws
}

enum MirrorCloudError: Error { case missingIdentity, systemServiceDisabledInTestHost }

@MainActor
final class SystemMirrorCloudBackend: MirrorCloudBackend {
    private lazy var container = CKContainer(identifier: CloudKitSchema.containerID)
    private static let subscriptionID = "throttle-snapshot-sub"

    private func requireProductionHost() throws {
        guard !CompanionRuntime.isTesting else { throw MirrorCloudError.systemServiceDisabledInTestHost }
    }

    func accountStatus() async throws -> CKAccountStatus {
        try requireProductionHost()
        return try await container.accountStatus()
    }
    func userRecordName() async throws -> String {
        try requireProductionHost()
        return try await container.userRecordID().recordName
    }

    func latestSnapshot() async throws -> ThrottleMirrorSnapshot? {
        try requireProductionHost()
        do {
            let record = try await container.privateCloudDatabase.record(
                for: CKRecord.ID(recordName: CloudKitSchema.recordName()))
            return try CloudKitRecordMapping.snapshot(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func ensureSubscription() async throws {
        try requireProductionHost()
        let database = container.privateCloudDatabase
        do {
            _ = try await database.subscription(for: Self.subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Only an absent subscription authorizes creating one. An arbitrary
            // serverRejectedRequest never proves that background pushes work.
        }
        let subscription = CKQuerySubscription(
            recordType: CloudKitSchema.recordType, predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID, options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }
}
