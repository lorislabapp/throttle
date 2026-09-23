import Foundation

/// Applies an exact reviewed proposal. The actor serializes this process; the
/// snapshot and target digests refuse cooperating or external concurrent edits.
actor ProjectInstructionReconciler {
    private struct Transaction {
        var proposal: ProjectInstructionProposal
        var review: ProjectInstructionReview
        var proposalDigest: String
        var root: URL
        var target: URL
        var previous: Data?
        var proposed: Data
        var now: Date
    }

    private let backupRoot: URL?

    init(backupRoot: URL? = nil) {
        self.backupRoot = backupRoot
    }

    func apply(
        _ proposal: ProjectInstructionProposal,
        review: ProjectInstructionReview,
        projectRoot: URL,
        now: Date = Date()
    ) throws -> ProjectInstructionApplyReceipt {
        let proposalDigest = try approvedDigest(proposal: proposal, review: review)
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        try validateSnapshot(proposal, root: root, now: now)
        let target = try ProjectInstructionService.instructionTarget(
            proposal.targetRelativePath,
            root: root
        )
        try refuseSymlinkComponents(target, root: root)
        let previous = try ProjectInstructionService.currentData(target, root: root)
        guard previous.map(ProjectInstructionService.digest) == proposal.expectedContentDigest else {
            throw ProjectInstructionError.staleTarget
        }
        let proposed = Data(proposal.proposedContent.utf8)
        guard ProjectInstructionService.digest(proposed) == proposal.proposedContentDigest else {
            throw ProjectInstructionError.verificationFailed
        }
        let transaction = Transaction(
            proposal: proposal,
            review: review,
            proposalDigest: proposalDigest,
            root: root,
            target: target,
            previous: previous,
            proposed: proposed,
            now: now
        )
        return try writeTransaction(transaction)
    }

    func rollback(_ receipt: ProjectInstructionApplyReceipt, projectRoot: URL) throws {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let evidence = try validatePersistedReceipt(receipt, root: root)
        let target = try ProjectInstructionService.instructionTarget(
            receipt.targetRelativePath,
            root: root
        )
        let current = try ProjectInstructionService.currentData(target, root: root)
        guard current.map(ProjectInstructionService.digest) == receipt.appliedContentDigest else {
            throw ProjectInstructionError.rollbackWouldOverwrite
        }
        if let backupPath = receipt.backupPath {
            let backup = URL(fileURLWithPath: backupPath)
            guard backup.standardizedFileURL.path
                    == evidence.appendingPathComponent("previous.bin").standardizedFileURL.path else {
                throw ProjectInstructionError.evidenceFailure
            }
            let data = try Data(contentsOf: backup)
            guard ProjectInstructionService.digest(data) == receipt.previousContentDigest else {
                throw ProjectInstructionError.verificationFailed
            }
            try data.write(to: target, options: .atomic)
        } else {
            guard receipt.previousContentDigest == nil else {
                throw ProjectInstructionError.evidenceFailure
            }
            try FileManager.default.removeItem(at: target)
        }
        let restored = try ProjectInstructionService.currentData(target, root: root)
        guard restored.map(ProjectInstructionService.digest) == receipt.previousContentDigest else {
            throw ProjectInstructionError.verificationFailed
        }
    }

    private func approvedDigest(
        proposal: ProjectInstructionProposal,
        review: ProjectInstructionReview
    ) throws -> String {
        guard proposal.schemaVersion == 1,
              let proposalDigest = proposal.digest,
              review.schemaVersion == 1,
              review.proposalDigest == proposalDigest,
              review.decision == .approved,
              !review.reviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectInstructionError.reviewRequired
        }
        return proposalDigest
    }

    private func validateSnapshot(
        _ proposal: ProjectInstructionProposal,
        root: URL,
        now: Date
    ) throws {
        let targetDirectory = try ProjectInstructionService.resolvedRelative(
            proposal.targetDirectory,
            root: root,
            directory: true
        )
        let current = try ProjectInstructionService.capture(
            projectRoot: root,
            targetDirectory: targetDirectory,
            now: now
        )
        guard current.digest == proposal.snapshotDigest else {
            throw ProjectInstructionError.staleSnapshot
        }
    }

    private func writeTransaction(
        _ transaction: Transaction
    ) throws -> ProjectInstructionApplyReceipt {
        let evidence = try evidenceDirectory(
            root: transaction.root,
            proposalDigest: transaction.proposalDigest
        )
        let backup = transaction.previous.map { _ in
            evidence.appendingPathComponent("previous.bin")
        }
        do {
            try createEvidenceDirectory(evidence)
            try writeJSON(transaction.proposal, to: evidence.appendingPathComponent("proposal.json"))
            try writeJSON(transaction.review, to: evidence.appendingPathComponent("review.json"))
            if let previous = transaction.previous, let backup {
                try previous.write(to: backup, options: .atomic)
            }
            try FileManager.default.createDirectory(
                at: transaction.target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try refuseSymlinkComponents(transaction.target, root: transaction.root)
            try transaction.proposed.write(to: transaction.target, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: transaction.target.path
            )
            guard try ProjectInstructionService.currentData(
                transaction.target,
                root: transaction.root
            ) == transaction.proposed else {
                throw ProjectInstructionError.verificationFailed
            }
            let receipt = receipt(
                transaction: transaction,
                evidence: evidence,
                backup: backup
            )
            try writeJSON(receipt, to: evidence.appendingPathComponent("receipt.json"))
            return receipt
        } catch {
            try? restore(transaction.previous, target: transaction.target)
            throw error
        }
    }

    private func receipt(
        transaction: Transaction,
        evidence: URL,
        backup: URL?
    ) -> ProjectInstructionApplyReceipt {
        ProjectInstructionApplyReceipt(
            proposalDigest: transaction.proposalDigest,
            snapshotDigest: transaction.proposal.snapshotDigest,
            targetRelativePath: transaction.proposal.targetRelativePath,
            previousContentDigest: transaction.previous.map(ProjectInstructionService.digest),
            appliedContentDigest: transaction.proposal.proposedContentDigest,
            appliedAt: transaction.now,
            evidenceDirectory: evidence.path,
            backupPath: backup?.path
        )
    }

    private func createEvidenceDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

private extension ProjectInstructionReconciler {
    private func evidenceDirectory(root: URL, proposalDigest: String) throws -> URL {
        guard isDigest(proposalDigest) else {
            throw ProjectInstructionError.evidenceFailure
        }
        let base: URL
        if let backupRoot {
            base = backupRoot
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            base = support.appendingPathComponent(
                "com.lorislab.throttle/instruction-reviews",
                isDirectory: true
            )
        }
        let rootDigest = ProjectInstructionService.digest(Data(root.path.utf8))
        return base.appendingPathComponent(rootDigest, isDirectory: true)
            .appendingPathComponent(proposalDigest, isDirectory: true)
    }

    private func validatePersistedReceipt(
        _ receipt: ProjectInstructionApplyReceipt,
        root: URL
    ) throws -> URL {
        guard receipt.schemaVersion == 1 else {
            throw ProjectInstructionError.evidenceFailure
        }
        let expected = try evidenceDirectory(root: root, proposalDigest: receipt.proposalDigest)
        let encodedReceipt = try encodedJSON(receipt)
        guard URL(fileURLWithPath: receipt.evidenceDirectory).standardizedFileURL.path
                == expected.standardizedFileURL.path,
              let persisted = FileManager.default.contents(
                  atPath: expected.appendingPathComponent("receipt.json").path
              ),
              persisted == encodedReceipt else {
            throw ProjectInstructionError.evidenceFailure
        }
        return expected
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func refuseSymlinkComponents(_ target: URL, root: URL) throws {
        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ProjectInstructionError.unsafeSource(current.path)
            }
        }
    }

    private func restore(_ previous: Data?, target: URL) throws {
        if let previous {
            try previous.write(to: target, options: .atomic)
        } else if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try encodedJSON(value).write(to: url, options: .atomic)
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
