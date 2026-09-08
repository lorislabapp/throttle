import CloudKit
import Foundation
import ThrottleShared

@MainActor
protocol CloudKitPublishingBackend: AnyObject {
    func accountStatus() async throws -> CKAccountStatus
    func save(_ snapshot: ThrottleMirrorSnapshot) async throws
    func cancel()
}

/// Publishes an opt-in, debounced mirror to the user's private CloudKit database.
/// Each start/account change owns a generation: stale account checks, timers and
/// saves cannot re-enable publishing or consume snapshots from a later account.
@MainActor
final class CloudKitPublisher: MirrorTransport {
    static let shared = CloudKitPublisher()

    private let makeBackend: () -> any CloudKitPublishingBackend
    private let notificationCenter: NotificationCenter
    private let sleep: (TimeInterval) async throws -> Void
    private let now: () -> Date
    private let minInterval: TimeInterval
    private var accountObserver: NSObjectProtocol?
    private var backend: (any CloudKitPublishingBackend)?
    private var startTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var generation = UUID()
    private var accountSubscription = UUID()
    private var requested = false
    private var enabled = false
    private var pending: ThrottleMirrorSnapshot?
    private var lastAttemptAt = Date.distantPast

    init(
        makeBackend: @escaping () -> any CloudKitPublishingBackend = { CloudKitDatabasePublisher() },
        notificationCenter: NotificationCenter = .default,
        minInterval: TimeInterval = 25,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.makeBackend = makeBackend
        self.notificationCenter = notificationCenter
        self.minInterval = minInterval
        self.now = now
        self.sleep = sleep
    }

    func start() {
        guard !requested else { return }
        requested = true
        let subscription = accountSubscription
        accountObserver = notificationCenter.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Revoke before returning to the main queue: an already queued flush
            // must not submit the previous account's snapshot under the new account.
            MainActor.assumeIsolated {
                guard let self, self.accountSubscription == subscription else { return }
                self.accountChanged()
            }
        }
        resolveAccount()
    }

    func stop() {
        requested = false
        accountSubscription = UUID()
        if let accountObserver { notificationCenter.removeObserver(accountObserver) }
        accountObserver = nil
        invalidate()
    }

    func publish(_ snapshot: ThrottleMirrorSnapshot) {
        // MirrorFanout retains this transport while opt-out is active. Do not
        // retain those snapshots for a future start or a different iCloud user.
        guard requested, backend != nil else { return }
        pending = snapshot
        scheduleFlush()
    }

    private func invalidate() {
        generation = UUID()
        enabled = false
        pending = nil
        startTask?.cancel()
        flushTask?.cancel()
        startTask = nil
        flushTask = nil
        backend?.cancel()
        backend = nil
        lastAttemptAt = .distantPast
    }

    private func accountChanged() {
        guard requested else { return }
        invalidate()
        resolveAccount()
    }

    private func resolveAccount() {
        let current = generation, candidate = makeBackend()
        backend = candidate
        startTask = Task { [weak self] in
            let status = try? await candidate.accountStatus()
            guard let self, self.generation == current, self.requested, !Task.isCancelled else { return }
            self.startTask = nil
            guard status == .available else {
                self.pending = nil
                self.backend = nil
                NSLog("[CloudKitPublisher] iCloud unavailable — mirror disabled")
                return
            }
            self.enabled = true
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard enabled, pending != nil, flushTask == nil, let backend else { return }
        let current = generation
        let wait = max(0, minInterval - now().timeIntervalSince(lastAttemptAt))
        flushTask = Task { [weak self] in
            guard let self else { return }
            do {
                if wait > 0 { try await self.sleep(wait) }
                guard self.generation == current, self.enabled, !Task.isCancelled,
                      let snapshot = self.pending else { return }
                self.pending = nil
                self.lastAttemptAt = self.now()
                try await backend.save(snapshot)
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                if let error = error as? CKError, error.code == .notAuthenticated {
                    self.accountChanged()
                    return
                }
                NSLog("[CloudKitPublisher] publish failed (retries on next change): \(error.localizedDescription)")
            }
            guard self.generation == current, self.enabled, !Task.isCancelled else { return }
            self.flushTask = nil
            self.scheduleFlush()
        }
    }
}

/// A submitted CloudKit write can already have reached the server at opt-out.
/// Cancel the operation, and let the publisher discard any late completion.
@MainActor
private final class CloudKitDatabasePublisher: CloudKitPublishingBackend {
    private let container = CKContainer(identifier: CloudKitSchema.containerID)
    private var operation: CKModifyRecordsOperation?

    func accountStatus() async throws -> CKAccountStatus { try await container.accountStatus() }

    func save(_ snapshot: ThrottleMirrorSnapshot) async throws {
        // allKeys needs no cached record/change tag. Never carry a record across accounts.
        let record = try CloudKitRecordMapping.record(from: snapshot)
        let write = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        write.savePolicy = .allKeys
        write.isAtomic = true
        operation = write
        defer { if operation === write { operation = nil } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                write.modifyRecordsResultBlock = { result in
                    continuation.resume(with: result.mapError { $0 as Error })
                }
                container.privateCloudDatabase.add(write)
            }
        } onCancel: {
            write.cancel()
        }
    }

    func cancel() { operation?.cancel() }
}
