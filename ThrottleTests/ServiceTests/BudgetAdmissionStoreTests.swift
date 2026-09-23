@testable import Throttle
import XCTest

final class BudgetAdmissionStoreTests: XCTestCase {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<BudgetAdmissionDecision, Error>] = []

        func append(_ value: Result<BudgetAdmissionDecision, Error>) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var snapshot: [Result<BudgetAdmissionDecision, Error>] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private var root = URL(fileURLWithPath: "/")
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-admission-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOrdinaryWorkCannotConsumeProtectedVerificationOrReleaseReserves() throws {
        let store = try makeStore(total: 100, verification: 20, release: 20)
        _ = try store.reserve(request(key: "ordinary", purpose: .ordinary, value: 60), now: start)

        XCTAssertThrowsError(try store.reserve(
            request(key: "too-much", purpose: .ordinary, value: 1),
            now: start
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .insufficient(.frontierTokens))
        }
        _ = try store.reserve(request(key: "verify", purpose: .verification, value: 20), now: start)
        _ = try store.reserve(request(key: "release", purpose: .release, value: 20), now: start)
        XCTAssertEqual(try store.snapshot(now: start).reservations.count, 3)
    }

    func testConcurrentStoresCannotBothSpendTheSameCapacity() throws {
        _ = try makeStore(total: 100, verification: 0, release: 0)
        let stores = [BudgetAdmissionStore(projectRoot: root), BudgetAdmissionStore(projectRoot: root)]
        let requests = (0..<2).map { index in
            request(key: "request-\(index)", purpose: .ordinary, value: 60)
        }
        let admissionTime = start
        let results = ResultBox()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            results.append(Result {
                try stores[index].reserve(requests[index], now: admissionTime)
            })
        }
        let values = results.snapshot
        XCTAssertEqual(values.filter {
            if case .success = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(values.filter {
            guard case .failure(let error) = $0 else { return false }
            return error as? BudgetAdmissionError == .insufficient(.frontierTokens)
        }.count, 1)
        XCTAssertEqual(
            try BudgetAdmissionStore(projectRoot: root).snapshot(now: start).reservations.count,
            1
        )
    }

    func testIdempotencyReturnsTheOriginalReservationAndRejectsChangedIntent() throws {
        let store = try makeStore(total: 100, verification: 0, release: 0)
        let original = request(key: "same", purpose: .ordinary, value: 30)
        let first = try store.reserve(original, now: start)
        let retry = try store.reserve(original, now: start)
        XCTAssertEqual(first, retry)

        XCTAssertThrowsError(try store.reserve(
            request(key: "same", purpose: .ordinary, value: 31),
            now: start
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .idempotencyConflict)
        }
    }

    func testExpiredReservationBlocksUntilExplicitlyReconciled() throws {
        let store = try makeStore(total: 50, verification: 0, release: 0)
        let old = try store.reserve(
            request(key: "old", purpose: .ordinary, value: 50, expiresAfter: 10),
            now: start
        ).reservation
        let fresh = BudgetAdmissionStore(projectRoot: root)
        XCTAssertThrowsError(try fresh.reserve(
            request(key: "new", purpose: .ordinary, value: 50, expiresAfter: 100),
            now: start.addingTimeInterval(11)
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .insufficient(.frontierTokens))
        }
        let states = try store.snapshot(now: start.addingTimeInterval(11)).reservations.map(\.state)
        XCTAssertEqual(states, [.expired])

        _ = try fresh.release(reservationID: old.id, now: start.addingTimeInterval(12))
        _ = try fresh.reserve(
            request(key: "new", purpose: .ordinary, value: 50, expiresAfter: 100),
            now: start.addingTimeInterval(13)
        )
    }

    func testActualOverrunIsRecordedAndBlocksNewAdmissions() throws {
        let store = try makeStore(total: 100, verification: 0, release: 0)
        let reservation = try store.reserve(
            request(key: "run", purpose: .ordinary, value: 40),
            now: start
        ).reservation
        let settled = try store.settle(
            reservationID: reservation.id,
            actualAmounts: [BudgetAmount(resource: .frontierTokens, value: 120)],
            fidelity: .exactMetered,
            evidenceRef: "receipt:provider-usage",
            now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(settled.countedAmount(for: .frontierTokens), 120)
        XCTAssertThrowsError(try store.reserve(
            request(key: "next", purpose: .ordinary, value: 1),
            now: start.addingTimeInterval(6)
        ))
    }

    func testLedgerIsPrivateAndExternalEnforcementRemainsUnavailable() throws {
        let store = try makeStore(total: 100, verification: 0, release: 0)
        let decision = try store.reserve(
            request(key: "run", purpose: .ordinary, value: 10),
            now: start
        )
        let ledger = root.appendingPathComponent(".throttle/budget/ledger.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: ledger.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        XCTAssertEqual(decision.externalEnforcement, .unavailable)
    }

    func testWorldReadableLedgerIsRefused() throws {
        let store = try makeStore(total: 100, verification: 0, release: 0)
        let ledger = root.appendingPathComponent(".throttle/budget/ledger.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: ledger.path
        )

        XCTAssertThrowsError(try store.snapshot(now: start)) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .unsafeStorage)
        }
    }

    func testSymlinkedThrottleDirectoryIsRefusedWithoutWritingThroughIt() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".throttle"),
            withDestinationURL: outside
        )
        let store = BudgetAdmissionStore(projectRoot: root)

        XCTAssertThrowsError(try store.bootstrap(
            capacities: [BudgetCapacity(
                resource: .frontierTokens,
                total: 100,
                protectedForVerification: 0,
                protectedForRelease: 0
            )],
            periodStartsAt: start,
            periodEndsAt: start.addingTimeInterval(100)
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .unsafeStorage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("budget").path))
    }

    func testCapabilityProfileRequiresEvidenceForEveryClaimedControl() {
        let unavailable = profile(control: .unavailable, evidence: nil)
        XCTAssertTrue(unavailable.isValid)
        XCTAssertFalse(profile(control: .exact, evidence: nil).isValid)
        XCTAssertTrue(profile(control: .betweenRequests, evidence: "receipt:probe").isValid)
    }

    func testUpperBoundSettlementCannotMasqueradeAsMeasuredUsage() throws {
        let store = try makeStore(total: 100, verification: 0, release: 0)
        let reservation = try store.reserve(
            request(key: "run", purpose: .ordinary, value: 40),
            now: start
        ).reservation

        XCTAssertThrowsError(try store.settle(
            reservationID: reservation.id,
            actualAmounts: [BudgetAmount(resource: .frontierTokens, value: 20)],
            fidelity: .reservedUpperBound,
            now: start.addingTimeInterval(5)
        )) { error in
            XCTAssertEqual(error as? BudgetAdmissionError, .invalidRequest)
        }
        let settled = try store.settle(
            reservationID: reservation.id,
            actualAmounts: reservation.request.amounts,
            fidelity: .reservedUpperBound,
            now: start.addingTimeInterval(6)
        )
        XCTAssertEqual(settled.settlementFidelity, .reservedUpperBound)
        XCTAssertNil(settled.settlementEvidenceRef)
    }

    private func makeStore(
        total: Int,
        verification: Int,
        release: Int
    ) throws -> BudgetAdmissionStore {
        let store = BudgetAdmissionStore(projectRoot: root)
        try store.bootstrap(
            capacities: [BudgetCapacity(
                resource: .frontierTokens,
                total: total,
                protectedForVerification: verification,
                protectedForRelease: release
            )],
            periodStartsAt: start,
            periodEndsAt: start.addingTimeInterval(1_000)
        )
        return store
    }

    private func request(
        key: String,
        purpose: BudgetPurpose,
        value: Int,
        expiresAfter: TimeInterval = 100
    ) -> BudgetReservationRequest {
        BudgetReservationRequest(
            idempotencyKey: key,
            taskID: "T1",
            purpose: purpose,
            amounts: [BudgetAmount(resource: .frontierTokens, value: value)],
            expiresAt: start.addingTimeInterval(expiresAfter),
            workContractDigest: String(repeating: "a", count: 64)
        )
    }

    private func profile(
        control: BackendControlFidelity,
        evidence: String?
    ) -> BackendCapabilityProfile {
        BackendCapabilityProfile(
            id: "provider/model/harness",
            model: "model",
            provider: "provider",
            billingAccountRef: nil,
            harness: "harness",
            executor: "local process",
            processingLocation: .cloud,
            executionLocation: .device,
            eventVisibility: .estimated,
            controls: [BackendControl(
                name: "per-request token cap",
                fidelity: control,
                evidenceRef: evidence
            )],
            observedAt: start,
            evidenceRefs: ["receipt:inventory"]
        )
    }
}
