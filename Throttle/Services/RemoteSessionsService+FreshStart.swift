import Foundation
import ThrottleShared

extension RemoteSessionsService {
    func refreshPendingStart() async {
        do {
            pendingStart = try await EdgeFreshSessionStarter.shared.pending()
            startRecoveryError = nil
        } catch {
            startRecoveryError = error.localizedDescription
        }
    }

    func resolvePendingStart(stop: Bool) async {
        guard isConfigured, !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }
        do {
            if stop {
                try await EdgeFreshSessionStarter.shared.stopPending(endpoint: baseURL, token: token)
                offloadStatus = "The saved server start is stopped. You can create another conversation."
            } else {
                _ = try await EdgeFreshSessionStarter.shared.retry(endpoint: baseURL, token: token)
                offloadStatus = "The original conversation is confirmed on the server."
            }
        } catch {
            offloadStatus = "Server start still needs recovery: \(error.localizedDescription)"
        }
        await refresh()
    }
}
