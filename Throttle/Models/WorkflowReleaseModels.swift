import CryptoKit
import Foundation

enum WorkflowReleaseManifestState: String, Codable, Sendable {
    case draft, frozen
}

enum WorkflowDistributionChannel: String, Codable, Sendable {
    case developerID
    case appStore
    case googlePlay
    case website
    case communications
}

struct WorkflowReleaseTarget: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var platform: WorkflowPlatform
    var distribution: WorkflowDistributionChannel
    var required: Bool = true

    var isValid: Bool {
        nonempty(id)
            && distributionIsCompatible
    }

    private var distributionIsCompatible: Bool {
        switch distribution {
        case .developerID: return platform == .macOS
        case .appStore: return [.macOS, .iOS, .visionOS].contains(platform)
        case .googlePlay: return platform == .android
        case .website, .communications: return platform == .web
        }
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Declarative release intent. Provider state and observations belong in the
/// release evidence ledger and never mutate this manifest after it is frozen.
struct WorkflowReleaseManifest: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var releaseID: String
    var manifestRevision: Int
    var previousManifestDigest: String?
    var state: WorkflowReleaseManifestState
    var productID: String
    var version: String
    var buildNumber: String
    var sourceRevision: String
    var targets: [WorkflowReleaseTarget]

    var isValid: Bool {
        let targetIDs = targets.map(\.id)
        return schemaVersion == 1
            && nonempty(releaseID)
            && manifestRevision > 0
            && previousDigestIsValid
            && nonempty(productID)
            && nonempty(version)
            && nonempty(buildNumber)
            && buildNumber.allSatisfy(\.isNumber)
            && isObjectID(sourceRevision)
            && !targets.isEmpty
            && targets.allSatisfy(\.isValid)
            && Set(targetIDs).count == targetIDs.count
            && targets.contains(where: \.required)
    }

    var digest: String? {
        guard isValid, let data = try? Self.encoder.encode(self) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var previousDigestIsValid: Bool {
        if manifestRevision == 1 { return previousManifestDigest == nil }
        return previousManifestDigest.map(isDigest) == true
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isObjectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

enum WorkflowReleaseGate: String, Codable, Sendable, CaseIterable {
    case manifestValidated
    case sourceVerified
    case testsAccepted
    case artifactTrusted
    case notarizationAccepted
    case stapleVerified
    case complianceAccepted
    case mediaAccepted
    case candidateAccepted
    case externalStateVerified
    case releaseClosed
}

enum WorkflowGateOutcome: String, Codable, Sendable {
    case passed, failed, notVerified
}

struct WorkflowReleaseGateEvidence: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var gate: WorkflowReleaseGate
    var targetID: String?
    var outcome: WorkflowGateOutcome
    var manifestDigest: String
    var sourceRevision: String
    var artifactDigest: String?
    var ref: String
    var observedAt: Date

    var isValid: Bool {
        (targetID.map(nonempty) ?? true)
            && isDigest(manifestDigest)
            && isObjectID(sourceRevision)
            && (artifactDigest.map(isDigest) ?? true)
            && nonempty(ref)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum WorkflowReleaseStage: String, Codable, Sendable {
    case prepare
    case notarize
    case publish
    case close
}

struct WorkflowExternalActionRequest: Codable, Sendable, Equatable {
    var action: String
    var targetID: String
    var audience: String
    var payloadDigest: String
}

/// An approval is exact and short lived. The holder still has to use a separate
/// adapter to perform the effect; this value grants no operating-system rights.
struct WorkflowExternalActionAuthorization: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var id: UUID
    var releaseID: String
    var manifestDigest: String
    var action: String
    var targetID: String
    var audience: String
    var payloadDigest: String
    var approvedBy: [String]
    var issuedAt: Date
    var expiresAt: Date
    var singleUse: Bool = true

    func refusal(
        request: WorkflowExternalActionRequest,
        manifest: WorkflowReleaseManifest,
        now: Date
    ) -> String? {
        guard schemaVersion == 1,
              let digest = manifest.digest,
              !approvedBy.isEmpty,
              approvedBy.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              issuedAt < expiresAt,
              expiresAt > now else {
            return "authorization_invalid_or_expired"
        }
        guard releaseID == manifest.releaseID, manifestDigest == digest else {
            return "authorization_manifest_mismatch"
        }
        guard action == request.action,
              targetID == request.targetID,
              audience == request.audience,
              payloadDigest == request.payloadDigest else {
            return "authorization_payload_mismatch"
        }
        return nil
    }
}

struct WorkflowReleaseEvaluation: Sendable, Equatable {
    var ready: Bool
    var blockers: [String]
}

enum WorkflowReleaseLedgerEventKind: String, Codable, Sendable {
    case gateObserved
    case effectPrepared
    case effectStarted
    case effectObserved
}

/// One immutable release fact. `effectStarted` is written before an external
/// adapter is called; after a crash it remains uncertain until a separately
/// observed provider receipt is appended.
struct WorkflowReleaseLedgerEvent: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var sequence: Int
    var eventID: UUID
    var previousDigest: String?
    var releaseID: String
    var manifestDigest: String
    var kind: WorkflowReleaseLedgerEventKind
    var actor: String
    var recordedAt: Date
    var gateEvidence: WorkflowReleaseGateEvidence?
    var actionRequest: WorkflowExternalActionRequest?
    var providerReceiptRef: String?

    var isValid: Bool {
        guard schemaVersion == 1,
              sequence > 0,
              nonempty(releaseID),
              isDigest(manifestDigest),
              nonempty(actor),
              previousDigest.map(isDigest) ?? true else { return false }
        switch kind {
        case .gateObserved:
            return gateEvidence?.isValid == true
                && gateEvidence?.manifestDigest == manifestDigest
                && actionRequest == nil
                && providerReceiptRef == nil
        case .effectPrepared, .effectStarted:
            return gateEvidence == nil
                && validAction(actionRequest)
                && providerReceiptRef == nil
        case .effectObserved:
            return gateEvidence == nil
                && validAction(actionRequest)
                && providerReceiptRef.map(nonempty) == true
        }
    }

    private func validAction(_ action: WorkflowExternalActionRequest?) -> Bool {
        guard let action else { return false }
        return nonempty(action.action)
            && nonempty(action.targetID)
            && nonempty(action.audience)
            && isDigest(action.payloadDigest)
    }

    private func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

enum WorkflowReleaseLedgerError: Error, Equatable {
    case invalidManifest
    case invalidEvent
    case unsafeStorage
    case corruptLedger
    case retryConflict
    case busy
}

enum WorkflowReleaseGateEvaluator {
    static func evaluate(
        manifest: WorkflowReleaseManifest,
        evidence: [WorkflowReleaseGateEvidence],
        stage: WorkflowReleaseStage,
        targetID: String? = nil,
        request: WorkflowExternalActionRequest? = nil,
        authorization: WorkflowExternalActionAuthorization? = nil,
        now: Date = Date()
    ) -> WorkflowReleaseEvaluation {
        guard let manifestDigest = manifest.digest else {
            return .init(ready: false, blockers: ["manifest_invalid"])
        }
        if stage != .prepare, manifest.state != .frozen {
            return .init(ready: false, blockers: ["manifest_not_frozen"])
        }
        let target = targetID.flatMap { id in manifest.targets.first { $0.id == id } }
        if targetID != nil, target == nil {
            return .init(ready: false, blockers: ["unknown_release_target"])
        }
        let currentEvidence = evidence.filter {
            $0.isValid
                && $0.manifestDigest == manifestDigest
                && $0.sourceRevision == manifest.sourceRevision
        }
        let required = requiredGates(stage: stage, target: target)
        var blockers = required.compactMap { gate -> String? in
            let matches = currentEvidence.filter {
                $0.gate == gate && evidenceTargetMatches($0, gate: gate, targetID: targetID)
            }
            guard matches.contains(where: { $0.outcome == .passed }) else {
                return "gate_not_passed:\(gate.rawValue)"
            }
            return matches.contains(where: { $0.outcome == .failed })
                ? "gate_contradiction:\(gate.rawValue)"
                : nil
        }
        if stage == .notarize || stage == .publish {
            guard let request else {
                blockers.append("external_action_request_missing")
                return .init(ready: false, blockers: blockers.sorted())
            }
            guard request.targetID == targetID else {
                blockers.append("external_action_target_mismatch")
                return .init(ready: false, blockers: blockers.sorted())
            }
            guard isDigest(request.payloadDigest) else {
                blockers.append("external_action_payload_invalid")
                return .init(ready: false, blockers: blockers.sorted())
            }
            if let refusal = authorization?.refusal(request: request, manifest: manifest, now: now) {
                blockers.append(refusal)
            } else if authorization == nil {
                blockers.append("external_action_authorization_missing")
            }
        }
        return .init(ready: blockers.isEmpty, blockers: blockers.sorted())
    }

    private static func requiredGates(
        stage: WorkflowReleaseStage,
        target: WorkflowReleaseTarget?
    ) -> Set<WorkflowReleaseGate> {
        var gates: Set<WorkflowReleaseGate> = [.manifestValidated, .sourceVerified, .testsAccepted]
        guard stage != .prepare else { return gates }
        gates.insert(.artifactTrusted)
        if stage == .publish || stage == .close {
            gates.formUnion([.candidateAccepted, .complianceAccepted])
            if target?.distribution == .developerID {
                gates.formUnion([.notarizationAccepted, .stapleVerified])
            }
            if target?.distribution == .appStore || target?.distribution == .googlePlay {
                gates.insert(.mediaAccepted)
            }
        }
        if stage == .close {
            gates.formUnion([.externalStateVerified, .releaseClosed])
        }
        return gates
    }

    private static func evidenceTargetMatches(
        _ evidence: WorkflowReleaseGateEvidence,
        gate: WorkflowReleaseGate,
        targetID: String?
    ) -> Bool {
        let global: Set<WorkflowReleaseGate> = [
            .manifestValidated, .sourceVerified, .testsAccepted, .complianceAccepted, .releaseClosed
        ]
        if global.contains(gate) { return evidence.targetID == nil || evidence.targetID == targetID }
        return targetID != nil && evidence.targetID == targetID
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
