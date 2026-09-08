import Foundation
import ThrottleShared

extension RemoteSessionsService {
    func bringBack(remoteID: String, localCwd: String) async -> String? {
        guard isConfigured else { return nil }
        do {
            guard var record = try RemoteTransferJournal.shared.records().first(where: { $0.id == remoteID }),
                  record.localCwd == localCwd, record.endpoint == baseURL else {
                offloadStatus = "Reconnect the original server and recover this transfer before resuming locally."
                return nil
            }
            let connection = record.connection(token: token)
            offloadStatus = "Stopping the remote conversation and freezing its work…"
            let stopped = try await EdgeTransferService.stop(record.request, using: connection)
            guard stopped.stopReceipt != nil else { throw EdgeTransferService.Failure.invalidStopReceipt }
            if record.phase != .returned {
                record.phase = .stopped
                try RemoteTransferJournal.shared.update(record)
            }
            let response = try await EdgeTransferService.freeze(record.request, using: connection)
            guard let manifest = response.frozen else { throw EdgeTransferService.Failure.invalidReturn }
            let directory = RemoteTransferJournal.shared.root.appendingPathComponent(record.id, isDirectory: true)
            offloadStatus = "Downloading and verifying the conversation and current work…"
            let transcript = try await EdgeTransferService.download(record.request, kind: "transcript",
                expected: manifest.transcript, directory: directory, using: connection)
            let bundle = try await EdgeTransferService.download(record.request, kind: "repo",
                expected: manifest.repo, directory: directory, using: connection)
            // A previous successful return can be retried before the UI clears its
            // saved remote ID. Revalidate local bytes before allowing the wake.
            var installing = record
            installing.phase = .stopped
            let installation = installing
            offloadStatus = "Checking local changes before restoring the returned work…"
            try await Task.detached(priority: .userInitiated) {
                try RemoteTransferReturn.install(record: installation, manifest: manifest,
                                                  transcript: transcript, bundle: bundle, directory: directory)
            }.value
            _ = try await EdgeTransferService.acknowledge(record.request, manifest: manifest, using: connection)
            record.phase = .returned
            record.returnedSHA256 = manifest.transcript.sha256
            try RemoteTransferJournal.shared.update(record)
            offloadStatus = "Conversation and work returned to the Mac. The server is stopped."
            await refresh()
            return record.nativeSessionID
        } catch {
            offloadStatus = "Return incomplete: \(error.localizedDescription)"
            return nil
        }
    }
}
