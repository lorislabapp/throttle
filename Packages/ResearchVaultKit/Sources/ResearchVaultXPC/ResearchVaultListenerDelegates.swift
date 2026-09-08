import Foundation
import ResearchVaultGateway
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultXPCClient

/// Listener delegate for a query-only endpoint. In production the surrounding
/// process creates one named listener per immutable policy. Ingestion is not
/// exposed by this protocol.
public final class ResearchVaultQueryListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let gateway: ResearchVaultGateway
    public let policy: ResearchVaultQueryEndpointPolicy

    public init(
        gateway: ResearchVaultGateway,
        policy: ResearchVaultQueryEndpointPolicy
    ) throws {
        try ResearchVaultCodeRequirement.validate(
            policy.authorizedClient.distributionRequirement
        )
        self.gateway = gateway
        self.policy = policy
        super.init()
    }

    public func configure(_ listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(
            policy.authorizedClient.distributionRequirement
        )
        listener.delegate = self
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: ResearchVaultQueryXPCProtocol.self
        )
        newConnection.exportedObject = ResearchVaultQueryService(gateway: gateway)
        newConnection.activate()
        return true
    }
}

public final class ResearchVaultOwnerListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable {
    private let projectAdmitter: ResearchVaultProjectAdmitter
    private let importer: ResearchVaultReceiptImporter
    private let quarantineLister: ResearchVaultQuarantineLister
    private let reviewer: ResearchVaultQuarantineReviewer
    private let exporter: ResearchVaultReceiptExporter
    private let reasoningPromoter: ResearchVaultReasoningPromoter
    private let reasoningQuerier: ResearchVaultReasoningQuerier
    public let policy: ResearchVaultOwnerEndpointPolicy

    public init(
        policy: ResearchVaultOwnerEndpointPolicy,
        projectAdmitter: @escaping ResearchVaultProjectAdmitter = { _ in
            throw ResearchVaultProjectAdmissionError.ownerRequired
        },
        importer: @escaping ResearchVaultReceiptImporter,
        quarantineLister: @escaping ResearchVaultQuarantineLister,
        reviewer: @escaping ResearchVaultQuarantineReviewer,
        exporter: @escaping ResearchVaultReceiptExporter,
        reasoningPromoter: @escaping ResearchVaultReasoningPromoter,
        reasoningQuerier: @escaping ResearchVaultReasoningQuerier
    ) throws {
        try ResearchVaultCodeRequirement.validate(
            policy.authorizedClient.distributionRequirement
        )
        self.policy = policy
        self.projectAdmitter = projectAdmitter
        self.importer = importer
        self.quarantineLister = quarantineLister
        self.reviewer = reviewer
        self.exporter = exporter
        self.reasoningPromoter = reasoningPromoter
        self.reasoningQuerier = reasoningQuerier
        super.init()
    }

    public func configure(_ listener: NSXPCListener) {
        listener.setConnectionCodeSigningRequirement(
            policy.authorizedClient.distributionRequirement
        )
        listener.delegate = self
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: ResearchVaultOwnerXPCProtocol.self
        )
        newConnection.exportedObject = ResearchVaultOwnerService(
            projectAdmitter: projectAdmitter,
            importer: importer,
            quarantineLister: quarantineLister,
            reviewer: reviewer,
            exporter: exporter,
            reasoningPromoter: reasoningPromoter,
            reasoningQuerier: reasoningQuerier
        )
        newConnection.activate()
        return true
    }
}
