import Foundation
import ThrottleShared

extension RemoteSessionsService {
    func reconcileTransfer(_ tab: CockpitTab, requestStop: Bool) async {
        guard !tab.isTransitioning, let nativeID = tab.sessionId else { return }
        tab.isTransferring = true
        defer { tab.isTransferring = false; MultiCockpitModel.shared.persist() }
        do {
            guard var record = try RemoteTransferJournal.shared.outstanding(
                runtime: tab.remoteRuntime, nativeID: nativeID), record.id == tab.offloadedRemoteID else {
                offloadStatus =
                    "This older transfer has no verified ownership record. Keep it on the server for recovery."
                return
            }
            guard baseURL == record.endpoint else {
                offloadStatus = "Reconnect the original server to reconcile this conversation."
                return
            }
            let connection = record.connection(token: token)
            let response = requestStop
                ? try await EdgeTransferService.stop(record.request, using: connection)
                : try await EdgeTransferService.status(record.request, using: connection)
            if ["stopped", "frozen", "returned"].contains(response.phase) {
                record.phase = .stopped
                try RemoteTransferJournal.shared.update(record)
                tab.resumeIssue = response.input == nil
                    ? """
                    The server scope is stopped, but its transfer metadata is missing. Keep both copies \
                    for recovery.
                    """
                    : "The server is stopped. Bring back its verified conversation and work before resuming locally."
                offloadStatus = tab.resumeIssue
            } else if response.phase == "remote" {
                record.phase = .remote
                try RemoteTransferJournal.shared.update(record)
                tab.resumeIssue = nil
                offloadStatus = "Remote ownership confirmed. This Mac remains suspended."
            } else {
                offloadStatus = "Transfer remains pending. Stop and reconcile it before starting another writer."
            }
            await refresh()
        } catch {
            offloadStatus = "Reconciliation incomplete: \(error.localizedDescription)"
        }
    }
}
