import Foundation

extension MultiCockpitModel {
    /// A missing/empty saved-window list cannot hide the durable transfer journal.
    /// Restore only metadata: no process, transcript overwrite or remote request.
    func restoreTransferTabs(journal: RemoteTransferJournal = .shared) {
        do {
            let records = try journal.records().filter(\.holdsLocalWriter)
            transferRecoveryCount = records.count
            transferRecoveryIssue = nil
            for record in records {
                let runtime: AgentRuntime = record.runtime == "codex" ? .codex : .claudeCode
                let matching = sessions.filter {
                    $0.runtime == runtime
                        && $0.sessionId?.caseInsensitiveCompare(record.nativeSessionID) == .orderedSame
                }
                if !matching.isEmpty {
                    guard matching.allSatisfy({ !$0.isSpawned && $0.cwd == record.localCwd }) else {
                        transferRecoveryIssue =
                            "An existing tab conflicts with a saved transfer. Stop it before recovery."
                        continue
                    }
                    for tab in matching { markTransferRecovery(tab, record: record) }
                    continue
                }
                let tab = CockpitTab(projectName: record.projectName, cwd: record.localCwd,
                                     runtime: runtime, resumeSessionId: record.nativeSessionID)
                markTransferRecovery(tab, record: record)
                wire(tab)
                sessions.append(tab)
            }
            recomputeSortOrder()
        } catch {
            transferRecoveryIssue = "Saved transfers need recovery: \(error.localizedDescription)"
        }
    }

    private func markTransferRecovery(_ tab: CockpitTab, record: RemoteTransferRecord) {
        tab.offloadedRemoteID = record.id
        tab.isHibernated = true
        tab.resumeIssue = "Remote transfer pending. Reconnect the original server and reconcile it before resuming."
    }
}
