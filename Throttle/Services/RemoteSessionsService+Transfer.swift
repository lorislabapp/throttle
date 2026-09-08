import Foundation
import ThrottleShared

extension RemoteSessionsService {
    /// The caller holds the tab's UI transition latch. Only capabilities are
    /// fetched before stopping locally; the journal is durable before prepare.
    func transferToServer(_ tab: CockpitTab) async -> String? {
        guard isConfigured, !tab.hasRemoteOwnership, let nativeID = tab.sessionId else { return nil }
        guard !hasLocalAlias(for: tab, nativeID: nativeID) else {
            offloadStatus = """
            Another local tab is using this conversation or choosing a session. Close its picker \
            or stop it before transferring.
            """
            return nil
        }
        guard let reservation = RemoteTransferReservation.acquire(runtime: tab.remoteRuntime, nativeID: nativeID) else {
            offloadStatus = "This conversation already has a transfer in progress."
            return nil
        }
        defer { RemoteTransferReservation.release(runtime: tab.remoteRuntime, nativeID: nativeID, token: reservation) }
        let endpoint = baseURL, credential = token
        let generation = tab.pauseGeneration
        do {
            offloadStatus = "Checking the server's transfer support…"
            let capabilities = try await EdgeTransferService.capabilities(endpoint: endpoint, token: credential)
            guard tab.pauseGeneration == generation, await tab.hibernate(), tab.sessionId == nativeID else {
                offloadStatus = tab.stopIssue ?? "The session changed before transfer. Try again from its current tab."
                return nil
            }
            let (record, bundle) = try await prepareTransfer(tab, nativeID: nativeID,
                                                            endpoint: endpoint, capabilities: capabilities)
            let id = record.id
            guard !hasLocalAlias(for: tab, nativeID: nativeID) else {
                throw RemoteTransferJournal.Failure.duplicateWriter
            }
            try RemoteTransferJournal.shared.begin(record)
            tab.offloadedRemoteID = id
            tab.resumeIssue = "Transfer pending. Local resume remains suspended until the server is reconciled."
            MultiCockpitModel.shared.persist()
            let response = try await startTransfer(record, bundle: bundle, credential: credential)
            guard response.phase == "remote" else {
                offloadStatus = "Remote start remains unresolved. Use Reconcile transfer before resuming locally."
                return id
            }
            var confirmed = record
            confirmed.phase = .remote
            try RemoteTransferJournal.shared.update(confirmed)
            tab.resumeIssue = nil
            offloadStatus = "Conversation and current work transferred to the server."
            await refresh()
            return id
        } catch {
            tab.restoreRemoteOwnership()
            offloadStatus = "Transfer incomplete: \(error.localizedDescription)"
            // The durable journal and tab ID intentionally remain on any network
            // failure. A vanished row or failed request cannot release ownership.
            return tab.offloadedRemoteID
        }
    }

    private func hasLocalAlias(for tab: CockpitTab, nativeID: String) -> Bool {
        MultiCockpitModel.shared.sessions.contains {
            $0 !== tab && $0.runtime == tab.runtime && $0.isSpawned
                && ($0.isChoosingNativeSession || $0.sessionId?.caseInsensitiveCompare(nativeID) == .orderedSame)
        }
    }

    private func startTransfer(
        _ record: RemoteTransferRecord, bundle: URL, credential: String
    ) async throws -> EdgeTransferService.Record {
        let input = record.request
        let connection = record.connection(token: credential)
        offloadStatus = "Uploading the conversation and current work…"
        _ = try await EdgeTransferService.prepare(input, using: connection)
        try await EdgeTransferService.upload(
            URL(fileURLWithPath: record.localTranscriptPath), kind: "transcript", input: input,
                                            expectedSHA256: record.baselineSHA256, using: connection)
        try await EdgeTransferService.upload(bundle, kind: "repo", input: input,
                                            expectedSHA256: record.repoSHA256, using: connection)
        offloadStatus = "Starting this conversation on the server…"
        return try await EdgeTransferService.start(input, using: connection)
    }

    private func prepareTransfer(
        _ tab: CockpitTab, nativeID: String, endpoint: String,
        capabilities: EdgeTransferService.Capabilities
    ) async throws
        -> (RemoteTransferRecord, URL) {
        let id = UUID().uuidString.lowercased()
        let remoteCwd = URL(fileURLWithPath: capabilities.workspaceRoot).appendingPathComponent(id).path
        let runtime = tab.runtime, localCwd = tab.cwd, projectName = tab.projectName
        let directory = RemoteTransferJournal.shared.root.appendingPathComponent(id, isDirectory: true)
        offloadStatus = "Preparing the conversation and current work…"
        let transcriptLimit = Self.transcriptOffloadLimit
        let prepared = try await Task.detached(priority: .userInitiated) {
            let codex = runtime == .codex ? MissionRuntimeService.codexRolloutURL(id: nativeID) : nil
            guard let transcript = NativeSessionBinding.knownTranscript(
                runtime: runtime, id: nativeID, cwd: localCwd, codexURLs: codex.map { [$0] } ?? []),
                  let size = try transcript.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size < transcriptLimit else {
                throw RemoteTransferGit.Failure.command("The exact transcript is unavailable or exceeds 128 MiB")
            }
            let hash = try RemoteTransferJournal.sha256(transcript.url)
            let snapshot = try RemoteTransferGit.snapshot(cwd: localCwd, transferID: id, directory: directory)
            return (transcript.url, hash, snapshot)
        }.value
        let record = RemoteTransferRecord(
            contractVersion: 2, id: id, endpoint: endpoint, serverID: capabilities.serverID,
            runtime: tab.remoteRuntime, nativeSessionID: nativeID, projectName: projectName,
            localCwd: localCwd, remoteCwd: remoteCwd, localTranscriptPath: prepared.0.path,
            baselineSHA256: prepared.1, repoSHA256: prepared.2.sha256,
            baselineGitTree: prepared.2.tree, nativeFilename: prepared.0.lastPathComponent,
            createdAt: Date(), phase: .prepared)
        return (record, prepared.2.bundle)
    }

}

extension RemoteTransferRecord {
    var request: EdgeTransferService.Input {
        .init(id: id, runtime: runtime, nativeSessionID: nativeSessionID, sourceCwd: localCwd,
              remoteCwd: remoteCwd, filename: nativeFilename, baselineSHA256: baselineSHA256, project: projectName)
    }
    func connection(token: String) -> EdgeTransferService.Connection {
        .init(endpoint: endpoint, token: token, serverID: serverID)
    }
}
