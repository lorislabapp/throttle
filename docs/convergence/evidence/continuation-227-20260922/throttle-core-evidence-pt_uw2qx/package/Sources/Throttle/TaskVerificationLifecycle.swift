import Foundation

/// Verification bookkeeping belongs to PlanStore, beside the task's checks.
/// No subprocess or external action is run while its mutation lock is held.
enum TaskVerificationLifecycle {
    struct Request {
        let command: String
        let stamp: String
        let author: String
        let timeout: TimeInterval
    }

    static func begin(
        taskID: String, store: PlanStore, request: Request, now: Date = Date()
    ) throws -> TaskVerificationLease {
        let (command, stamp, author, timeout) = (request.command, request.stamp, request.author, request.timeout)
        guard !author.isEmpty, !command.isEmpty, !stamp.isEmpty,
              timeout.isFinite, timeout > 0, timeout <= 86_400 else {
            throw TaskVerificationError.invalidRequest
        }
        return try store.mutate { store in
            let state = try store.state(for: taskID)
            guard state.chainValid else { throw PlanStoreError.invalidLog(taskID) }
            if let pending = state.pendingVerification {
                throw TaskVerificationError.unresolvedExecution(pending.id)
            }
            guard state.status == .candidate || state.status == .done else {
                throw TaskVerificationError.ineligibleTask
            }
            let history = try store.events(for: taskID).events
            let fence = (history.last?.seq ?? 0) + 1
            let receipt = WorkflowEvidenceReceipt.command(command, stamp: stamp, startedAt: now,
                finishedAt: now, result: (false, false))
            let lease = TaskVerificationLease(
                id: UUID(), fence: fence, owner: author, missionID: state.missionID,
                inputStamp: stamp, commandDigest: receipt.commandDigest,
                expiresAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 + timeout + 60))
            )
            var event = TaskEvent(seq: 0, timestamp: now, author: author, type: .verificationStarted,
                                  ref: stamp, reason: "Execution admitted; outcome not yet observed.")
            event.verificationLease = lease
            try store.append(event, to: taskID, expectedSequence: fence - 1)
            return lease
        }
    }

    /// Bind the gated direct child to its durable intent before admission.
    /// A failed append leaves the child unable to execute the project command.
    static func attachProcess(
        taskID: String, store: PlanStore, lease: TaskVerificationLease,
        process: TaskVerificationProcess, now: Date = Date()
    ) throws {
        try store.mutate { store in
            let state = try store.state(for: taskID)
            guard state.chainValid, state.pendingVerification == lease,
                  state.verificationProcess == nil, process.isValid, now < lease.expiresAt else {
                throw TaskVerificationError.staleExecution
            }
            var event = TaskEvent(seq: 0, timestamp: now, author: lease.owner, type: .verificationProcessAttached)
            event.verificationLease = lease
            event.verificationProcess = process
            try store.append(event, to: taskID)
        }
    }

    /// Only a matching, current lease can acknowledge the command. A completion
    /// arriving after expiry is recorded as incomplete, never as a passing check.
    static func finish(
        taskID: String, store: PlanStore, lease: TaskVerificationLease,
        checked: TaskEvent, now: Date = Date()
    ) throws -> TaskEvent {
        try store.mutate { store in
            let state = try store.state(for: taskID)
            guard state.chainValid, state.pendingVerification == lease,
                  checked.type == .checked, checked.author == lease.owner,
                  checked.ref == lease.inputStamp,
                  checked.receipt?.commandDigest == lease.commandDigest,
                  checked.receipt?.inputStamp == lease.inputStamp else {
                throw TaskVerificationError.staleExecution
            }
            var event = checked
            event.verificationLease = lease
            if now >= lease.expiresAt {
                event.passed = false
                event.receipt?.outcome = .incomplete
                event.reason = "Verification lease expired; late evidence is incomplete."
            }
            return try store.append(event, to: taskID)
        }
    }

    /// Trusted recovery records an operator/controller's separate observation
    /// that the old execution is stopped. It never certifies the task or retries
    /// the command. Callers must verify that observation, not infer it from TTL.
    static func acknowledgeStoppedExecution(
        taskID: String, store: PlanStore, lease: TaskVerificationLease,
        observedBy: String, evidenceRef: String, now: Date = Date()
    ) throws {
        guard !observedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !evidenceRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskVerificationError.recoveryEvidenceRequired
        }
        try store.mutate { store in
            let state = try store.state(for: taskID)
            guard state.chainValid, state.pendingVerification == lease else {
                throw TaskVerificationError.staleExecution
            }
            var event = TaskEvent(seq: 0, timestamp: now, author: observedBy, type: .verificationAbandoned,
                                  ref: evidenceRef, reason: "Stopped execution acknowledged; result remains unknown.")
            event.verificationLease = lease
            try store.append(event, to: taskID)
        }
    }
}
