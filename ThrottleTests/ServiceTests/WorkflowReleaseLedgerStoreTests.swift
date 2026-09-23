import Darwin
import Foundation
import Testing
@testable import Throttle

@Suite("Workflow release ledger")
struct WorkflowReleaseLedgerStoreTests {
    @Test("an interrupted external effect remains explicitly unresolved")
    func startedEffectNeedsProviderObservation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = fixture.request
        _ = try fixture.store.append(
            fixture.event(.effectPrepared, request: request),
            manifest: fixture.manifest
        )
        _ = try fixture.store.append(
            fixture.event(.effectStarted, request: request),
            manifest: fixture.manifest,
            authorization: fixture.authorization,
            now: fixture.now
        )
        #expect(try fixture.store.unresolvedEffects(releaseID: fixture.manifest.releaseID) == [request])
        _ = try fixture.store.append(
            fixture.event(.effectObserved, request: request, providerRef: "apple://receipt/1"),
            manifest: fixture.manifest
        )
        #expect(try fixture.store.unresolvedEffects(releaseID: fixture.manifest.releaseID).isEmpty)
    }

    @Test("starting an effect requires both prepared intent and exact authorization")
    func startRequiresExactAuthorization() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.append(
            fixture.event(.effectPrepared, request: fixture.request),
            manifest: fixture.manifest
        )
        #expect(throws: WorkflowReleaseLedgerError.invalidEvent) {
            try fixture.store.append(
                fixture.event(.effectStarted, request: fixture.request),
                manifest: fixture.manifest
            )
        }
        var changed = fixture.request
        changed.payloadDigest = String(repeating: "f", count: 64)
        #expect(throws: WorkflowReleaseLedgerError.invalidEvent) {
            try fixture.store.append(
                fixture.event(.effectStarted, request: changed),
                manifest: fixture.manifest,
                authorization: fixture.authorization
            )
        }
    }

    @Test("retrying the same event is idempotent and conflicting reuse is refused")
    func eventIdentityIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let event = fixture.event(.effectPrepared, request: fixture.request)
        let first = try fixture.store.append(event, manifest: fixture.manifest)
        let retry = try fixture.store.append(event, manifest: fixture.manifest)
        #expect(first == retry)
        var conflict = event
        conflict.actor = "different:actor"
        #expect(throws: WorkflowReleaseLedgerError.retryConflict) {
            try fixture.store.append(conflict, manifest: fixture.manifest)
        }
    }

    @Test("a fractional timestamp survives an exact retry")
    func fractionalTimestampIsStable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var event = fixture.event(.effectPrepared, request: fixture.request)
        event.recordedAt = Date(timeIntervalSince1970: 1_000.123_456_789)
        let first = try fixture.store.append(event, manifest: fixture.manifest)
        let retry = try fixture.store.append(event, manifest: fixture.manifest)
        #expect(first == retry)
    }

    @Test("an external effect target must exist in the frozen manifest")
    func unknownTargetIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var request = fixture.request
        request.targetID = "missing-target"
        #expect(throws: WorkflowReleaseLedgerError.invalidEvent) {
            try fixture.store.append(
                fixture.event(.effectPrepared, request: request),
                manifest: fixture.manifest
            )
        }
    }

    @Test("a torn final line is corruption and is never silently repaired")
    func tornWriteFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.store.append(
            fixture.event(.effectPrepared, request: fixture.request),
            manifest: fixture.manifest
        )
        let url = fixture.root.appendingPathComponent(
            ".throttle/releases/\(fixture.manifest.releaseID).ndjson"
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))
        try handle.close()
        #expect(throws: WorkflowReleaseLedgerError.corruptLedger) {
            try fixture.store.events(releaseID: fixture.manifest.releaseID)
        }
    }
}

private struct Fixture {
    let root: URL
    let store: WorkflowReleaseLedgerStore
    let manifest: WorkflowReleaseManifest
    let request: WorkflowExternalActionRequest
    let authorization: WorkflowExternalActionAuthorization
    let now = Date(timeIntervalSince1970: 1_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WorkflowReleaseLedgerStore(projectRoot: root)
        manifest = WorkflowReleaseManifest(
            releaseID: "throttle-3.7.0-221",
            manifestRevision: 1,
            state: .frozen,
            productID: "throttle",
            version: "3.7.0",
            buildNumber: "221",
            sourceRevision: String(repeating: "a", count: 40),
            targets: [WorkflowReleaseTarget(
                id: "mac-direct",
                platform: .macOS,
                distribution: .developerID
            )]
        )
        request = WorkflowExternalActionRequest(
            action: "release.publish",
            targetID: "mac-direct",
            audience: "public",
            payloadDigest: String(repeating: "e", count: 64)
        )
        authorization = WorkflowExternalActionAuthorization(
            id: UUID(),
            releaseID: manifest.releaseID,
            manifestDigest: manifest.digest ?? "",
            action: request.action,
            targetID: request.targetID,
            audience: request.audience,
            payloadDigest: request.payloadDigest,
            approvedBy: ["user:kevin"],
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(600)
        )
    }

    func event(
        _ kind: WorkflowReleaseLedgerEventKind,
        request: WorkflowExternalActionRequest,
        providerRef: String? = nil
    ) -> WorkflowReleaseLedgerEvent {
        WorkflowReleaseLedgerEvent(
            sequence: 0,
            eventID: UUID(),
            releaseID: manifest.releaseID,
            manifestDigest: manifest.digest ?? "",
            kind: kind,
            actor: "throttle:test",
            recordedAt: now,
            actionRequest: request,
            providerReceiptRef: providerRef
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
