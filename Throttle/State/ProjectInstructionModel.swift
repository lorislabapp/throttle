import Foundation
import Observation

@MainActor
@Observable
final class ProjectInstructionModel {
    private(set) var snapshot: ProjectInstructionSnapshot?
    private(set) var proposal: ProjectInstructionProposal?
    private(set) var currentContent = ""
    private(set) var receipt: ProjectInstructionApplyReceipt?
    private(set) var status = String(localized: "Scan the project before proposing a change.")
    private(set) var isApplying = false

    private var root: URL?
    private let reconciler: ProjectInstructionReconciler

    init(reconciler: ProjectInstructionReconciler = ProjectInstructionReconciler()) {
        self.reconciler = reconciler
    }

    var sources: [ProjectInstructionSource] { snapshot?.sources ?? [] }
    var snapshotDigest: String? { snapshot?.digest }

    func bind(to projectRoot: URL) {
        guard root?.path != projectRoot.path else { return }
        root = projectRoot
        proposal = nil
        receipt = nil
        refresh()
    }

    func refresh() {
        guard let root else { return }
        do {
            snapshot = try ProjectInstructionService.capture(
                projectRoot: root,
                targetDirectory: root
            )
            status = String(localized: "Found \(sources.count) applicable instruction source(s).")
        } catch {
            snapshot = nil
            status = String(localized: "Instruction scan refused: \(String(describing: error))")
        }
    }

    func prepare(
        targetRelativePath: String,
        sectionID: String,
        title: String,
        statement: String,
        sourceRefs: [String]
    ) {
        guard let root, let snapshot else {
            status = String(localized: "Scan the project before preparing a diff.")
            return
        }
        let section = ProjectInstructionSection(
            id: sectionID,
            revision: 1,
            title: title,
            statements: [
                ProjectInstructionStatement(
                    id: sectionID + "-1",
                    text: statement,
                    status: .confirmed,
                    sourceRefs: sourceRefs
                )
            ]
        )
        do {
            let target = try ProjectInstructionService.instructionTarget(
                targetRelativePath,
                root: root
            )
            let existing = try ProjectInstructionService.currentData(target, root: root)
            currentContent = try existing.map(decodeUTF8) ?? ""
            proposal = try ProjectInstructionService.propose(
                projectRoot: root,
                snapshot: snapshot,
                targetRelativePath: targetRelativePath,
                section: section
            )
            status = proposal == nil
                ? String(localized: "No change: the managed section already matches.")
                : String(localized: "Exact proposal ready for review. No file has been changed.")
        } catch {
            proposal = nil
            status = String(localized: "Proposal refused: \(String(describing: error))")
        }
    }

    func applyReviewedProposal() async {
        guard let root, let proposal, let proposalDigest = proposal.digest else {
            status = String(localized: "Prepare and review an exact proposal first.")
            return
        }
        isApplying = true
        defer { isApplying = false }
        let review = ProjectInstructionReview(
            proposalDigest: proposalDigest,
            decision: .approved,
            reviewer: "local-user",
            reviewedAt: Date()
        )
        do {
            let receipt = try await reconciler.apply(
                proposal,
                review: review,
                projectRoot: root
            )
            guard self.root?.path == root.path else { return }
            self.receipt = receipt
            self.proposal = nil
            refresh()
            status = String(localized: "Reviewed instructions applied and verified.")
        } catch {
            status = String(localized: "Apply refused: \(String(describing: error))")
        }
    }

    func rollbackLastApply() async {
        guard let root, let receipt else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try await reconciler.rollback(receipt, projectRoot: root)
            guard self.root?.path == root.path else { return }
            self.receipt = nil
            refresh()
            status = String(localized: "Last instruction change rolled back and verified.")
        } catch {
            status = String(localized: "Rollback refused: \(String(describing: error))")
        }
    }

    private func decodeUTF8(_ data: Data) throws -> String {
        guard let value = String(bytes: data, encoding: .utf8) else {
            throw ProjectInstructionError.unsafeSource("non-UTF-8 instruction file")
        }
        return value
    }
}
