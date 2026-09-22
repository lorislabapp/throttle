import Darwin
import Foundation

/// Private lifecycle store for synthetic, local-only adversarial campaigns.
/// It executes no shell and exposes no network primitive: a caller may record
/// observations only for the exact fixture inside the independently supplied
/// sandbox root.
final class RedTeamCampaignStore: @unchecked Sendable {
    let projectRoot: URL
    let allowedSandboxRoot: URL
    let files = FileManager.default
    let processLock = NSRecursiveLock()

    init(projectRoot: URL, allowedSandboxRoot: URL) {
        self.projectRoot = Self.resolved(projectRoot)
        self.allowedSandboxRoot = Self.resolved(allowedSandboxRoot)
    }

    func bootstrap(_ campaign: RedTeamCampaign) throws {
        guard confined(campaign) else { throw RedTeamCampaignError.unsafeCampaign }
        try withLock {
            let url = campaignURL(campaign.id)
            var info = stat()
            guard lstat(url.path, &info) != 0, errno == ENOENT else {
                throw RedTeamCampaignError.campaignAlreadyExists
            }
            try write(RedTeamCampaignLedger(campaign: canonical(campaign)), to: url)
        }
    }

    func snapshot(_ campaignID: UUID) throws -> RedTeamCampaignLedger {
        try withLock { try load(campaignID) }
    }

    @discardableResult
    func observe(
        campaignID: UUID,
        observation: WorkflowFindingObservation
    ) throws -> WorkflowSecurityFinding {
        try withLock {
            var ledger = try load(campaignID)
            guard ledger.campaign.scenarioIDs.contains(observation.scenarioID) else {
                throw RedTeamCampaignError.unsafeCampaign
            }
            let finding = WorkflowSecurityFinding(
                id: UUID(),
                campaignID: campaignID,
                scenarioID: observation.scenarioID,
                component: observation.component,
                targetRevision: ledger.campaign.targetRevision,
                preconditions: observation.preconditions,
                evidence: observation.evidence,
                impact: observation.impact,
                status: .suspected,
                discoveredBy: observation.challenger,
                discoveredAt: observation.observedAt
            )
            guard finding.isValid else { throw RedTeamCampaignError.invalidEvidence }
            if let existing = ledger.findings.first(where: { $0.fingerprint == finding.fingerprint }) {
                return existing
            }
            ledger.findings.append(finding)
            ledger.revision += 1
            guard ledger.isValid else { throw RedTeamCampaignError.invalidLedger }
            try write(ledger, to: campaignURL(campaignID))
            return finding
        }
    }

    @discardableResult
    func triage(
        campaignID: UUID,
        findingID: UUID,
        triage: WorkflowFindingTriage
    ) throws -> WorkflowSecurityFinding {
        try update(campaignID, findingID: findingID) { finding in
            guard finding.status == .suspected,
                  Self.nonempty(triage.justification),
                  Self.nonempty(triage.analyst) else {
                throw RedTeamCampaignError.invalidTransition
            }
            finding.status = .confirmed
            finding.severity = triage.severity
            finding.severityJustification = triage.justification
            finding.triagedBy = triage.analyst
            finding.triagedAt = triage.triagedAt
        }
    }

    @discardableResult
    func submitRemediation(
        campaignID: UUID,
        findingID: UUID,
        remediation: WorkflowFindingRemediation
    ) throws -> WorkflowSecurityFinding {
        try update(campaignID, findingID: findingID) { finding in
            guard finding.status == .confirmed || finding.status == .retestFailed,
                  remediation.candidateRevision != finding.targetRevision,
                  Self.nonempty(remediation.candidateRevision),
                  Self.nonempty(remediation.taskID),
                  Self.nonempty(remediation.submittedBy),
                  !remediation.evidence.isEmpty,
                  remediation.evidence.allSatisfy(\.isValid) else {
                throw RedTeamCampaignError.invalidTransition
            }
            finding.remediation = remediation
            finding.status = .remediationCandidate
        }
    }

    @discardableResult
    func recordRetest(
        campaignID: UUID,
        findingID: UUID,
        retest: WorkflowFindingRetest
    ) throws -> WorkflowSecurityFinding {
        try update(campaignID, findingID: findingID) { finding in
            guard finding.status == .remediationCandidate,
                  let remediation = finding.remediation else {
                throw RedTeamCampaignError.invalidTransition
            }
            guard retest.testedBy != remediation.submittedBy else {
                throw RedTeamCampaignError.correlatedRetest
            }
            guard retest.candidateRevision == remediation.candidateRevision,
                  Self.nonempty(retest.regressionID),
                  Self.nonempty(retest.testedBy),
                  !retest.evidence.isEmpty,
                  retest.evidence.allSatisfy(\.isValid) else {
                throw RedTeamCampaignError.invalidEvidence
            }
            finding.retests.append(retest)
            finding.status = retest.passed ? .retestPassed : .retestFailed
        }
    }

    @discardableResult
    func markIntegrated(
        campaignID: UUID,
        findingID: UUID,
        revision: String,
        by coordinator: String
    ) throws -> WorkflowSecurityFinding {
        try update(campaignID, findingID: findingID) { finding in
            guard finding.status == .retestPassed,
                  coordinator != finding.remediation?.submittedBy,
                  Self.nonempty(coordinator),
                  Self.nonempty(revision),
                  revision == finding.remediation?.candidateRevision else {
                throw RedTeamCampaignError.invalidTransition
            }
            finding.status = .integrated
            finding.integratedRevision = revision
        }
    }

    @discardableResult
    func markDelivered(
        campaignID: UUID,
        findingID: UUID,
        version: String,
        by coordinator: String
    ) throws -> WorkflowSecurityFinding {
        try update(campaignID, findingID: findingID) { finding in
            guard finding.status == .integrated,
                  coordinator != finding.remediation?.submittedBy,
                  Self.nonempty(coordinator),
                  Self.nonempty(version) else {
                throw RedTeamCampaignError.invalidTransition
            }
            finding.status = .delivered
            finding.deliveredVersion = version
        }
    }

    private func update(
        _ campaignID: UUID,
        findingID: UUID,
        body: (inout WorkflowSecurityFinding) throws -> Void
    ) throws -> WorkflowSecurityFinding {
        try mutate(campaignID) { ledger in
            guard let index = ledger.findings.firstIndex(where: { $0.id == findingID }) else {
                throw RedTeamCampaignError.unknownFinding
            }
            try body(&ledger.findings[index])
            return ledger.findings[index]
        }
    }

    private func mutate<T>(
        _ campaignID: UUID,
        body: (inout RedTeamCampaignLedger) throws -> T
    ) throws -> T {
        try withLock {
            var ledger = try load(campaignID)
            let value = try body(&ledger)
            ledger.revision += 1
            guard ledger.isValid else { throw RedTeamCampaignError.invalidLedger }
            try write(ledger, to: campaignURL(campaignID))
            return value
        }
    }

    func confined(_ campaign: RedTeamCampaign) -> Bool {
        guard campaign.isValid else { return false }
        let fixture = Self.resolved(URL(fileURLWithPath: campaign.fixtureRoot, isDirectory: true))
        let target = Self.resolved(URL(fileURLWithPath: campaign.targetRoot, isDirectory: true))
        let boundary = allowedSandboxRoot.path.hasSuffix("/")
            ? allowedSandboxRoot.path
            : allowedSandboxRoot.path + "/"
        var isDirectory: ObjCBool = false
        return fixture.path.hasPrefix(boundary)
            && fixture == target
            && files.fileExists(atPath: fixture.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && campaign.networkPolicy == .denied
    }

    private func canonical(_ campaign: RedTeamCampaign) -> RedTeamCampaign {
        var value = campaign
        value.fixtureRoot = Self.resolved(
            URL(fileURLWithPath: campaign.fixtureRoot, isDirectory: true)
        ).path
        value.targetRoot = value.fixtureRoot
        return value
    }

}
