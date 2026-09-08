import Foundation

extension CockpitTab {
    var remoteRuntime: String { runtime == .codex ? "codex" : "claude" }

    /// Check durable state at every launch entry point, including restored tabs
    /// and another tab that resumes the same native identity.
    var hasRemoteOwnership: Bool {
        if offloadedRemoteID != nil { return true }
        guard runtime.usesTranscript, let sessionId else { return false }
        if RemoteTransferReservation.contains(runtime: remoteRuntime, nativeID: sessionId) { return true }
        do {
            return try RemoteTransferJournal.shared.outstanding(runtime: remoteRuntime, nativeID: sessionId) != nil
        } catch {
            return true
        }
    }

    func restoreRemoteOwnership() {
        guard runtime.usesTranscript, let sessionId else { return }
        do {
            if let transfer = try RemoteTransferJournal.shared.outstanding(
                runtime: remoteRuntime, nativeID: sessionId) {
                offloadedRemoteID = transfer.id
                isHibernated = true
                resumeIssue = "Remote transfer pending. Reconcile it before resuming this session locally."
            }
        } catch {
            resumeIssue = error.localizedDescription
        }
    }
}
