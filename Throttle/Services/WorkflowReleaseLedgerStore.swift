import CryptoKit
import Darwin
import Foundation

/// Private, append-only evidence for release work. This store never invokes a
/// provider. It records intent before an adapter call and a separate observation
/// afterwards, leaving interrupted effects explicitly uncertain.
final class WorkflowReleaseLedgerStore: @unchecked Sendable {
    let projectRoot: URL
    let files = FileManager.default
    let processLock = NSRecursiveLock()

    init(projectRoot: URL) {
        self.projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    func append(
        _ proposed: WorkflowReleaseLedgerEvent,
        manifest: WorkflowReleaseManifest,
        authorization: WorkflowExternalActionAuthorization? = nil,
        now: Date = Date()
    ) throws -> WorkflowReleaseLedgerEvent {
        guard let digest = manifest.digest,
              manifest.releaseID == proposed.releaseID,
              digest == proposed.manifestDigest else {
            throw WorkflowReleaseLedgerError.invalidManifest
        }
        return try withLedger(manifest.releaseID) { descriptor, events, lines in
            if let existing = events.first(where: { $0.eventID == proposed.eventID }) {
                var comparable = proposed
                comparable.sequence = existing.sequence
                comparable.previousDigest = existing.previousDigest
                guard comparable == existing else { throw WorkflowReleaseLedgerError.retryConflict }
                return existing
            }
            var event = proposed
            event.sequence = events.count + 1
            event.previousDigest = lines.last.map(Self.sha256)
            guard event.isValid else { throw WorkflowReleaseLedgerError.invalidEvent }
            try validateTransition(event, history: events, manifest: manifest,
                                   authorization: authorization, now: now)
            let line = try Self.encoder.encode(event)
            try appendLine(line, descriptor: descriptor)
            return event
        }
    }

    func events(releaseID: String) throws -> [WorkflowReleaseLedgerEvent] {
        try withLedger(releaseID) { _, events, _ in events }
    }

    func unresolvedEffects(releaseID: String) throws -> [WorkflowExternalActionRequest] {
        let history = try events(releaseID: releaseID)
        let starts = history.filter { $0.kind == .effectStarted }.compactMap(\.actionRequest)
        let observed = Set(history.filter { $0.kind == .effectObserved }.compactMap {
            $0.actionRequest.map(Self.actionKey)
        })
        return starts.filter { !observed.contains(Self.actionKey($0)) }
    }

    func releaseEvidence(releaseID: String) throws -> [WorkflowReleaseGateEvidence] {
        try events(releaseID: releaseID).compactMap(\.gateEvidence)
    }

    private func validateTransition(
        _ event: WorkflowReleaseLedgerEvent,
        history: [WorkflowReleaseLedgerEvent],
        manifest: WorkflowReleaseManifest,
        authorization: WorkflowExternalActionAuthorization?,
        now: Date
    ) throws {
        if let evidence = event.gateEvidence {
            guard evidence.sourceRevision == manifest.sourceRevision else {
                throw WorkflowReleaseLedgerError.invalidEvent
            }
            return
        }
        try validateActionTransition(
            event,
            history: history,
            manifest: manifest,
            authorization: authorization,
            now: now
        )
    }

    private func validateActionTransition(
        _ event: WorkflowReleaseLedgerEvent,
        history: [WorkflowReleaseLedgerEvent],
        manifest: WorkflowReleaseManifest,
        authorization: WorkflowExternalActionAuthorization?,
        now: Date
    ) throws {
        guard let request = event.actionRequest else { throw WorkflowReleaseLedgerError.invalidEvent }
        guard manifest.targets.contains(where: { $0.id == request.targetID }) else {
            throw WorkflowReleaseLedgerError.invalidEvent
        }
        let prior = history.filter { $0.actionRequest.map(Self.actionKey) == Self.actionKey(request) }
        switch event.kind {
        case .effectPrepared:
            guard prior.isEmpty else { throw WorkflowReleaseLedgerError.invalidEvent }
        case .effectStarted:
            guard prior.last?.kind == .effectPrepared,
                  let authorization,
                  authorization.refusal(request: request, manifest: manifest, now: now) == nil else {
                throw WorkflowReleaseLedgerError.invalidEvent
            }
        case .effectObserved:
            guard prior.last?.kind == .effectStarted else {
                throw WorkflowReleaseLedgerError.invalidEvent
            }
        case .gateObserved:
            throw WorkflowReleaseLedgerError.invalidEvent
        }
    }

    static func actionKey(_ request: WorkflowExternalActionRequest) -> String {
        [request.action, request.targetID, request.audience, request.payloadDigest]
            .joined(separator: "\u{1f}")
    }
}
