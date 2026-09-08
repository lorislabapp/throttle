import Foundation

@MainActor
extension CockpitTab {
    /// The shell command that launches this tab's agent, including the resume
    /// id, the heap cap and any handoff prompt. Extracted from `ensureSpawned`
    /// so it can be re-issued into the SHELL THAT IS ALREADY THERE when the
    /// agent exits under us — relaunching needs the same command, not a new
    /// terminal.
    func agentCommand(home: URL = .homeDirectory, journal: RemoteTransferJournal? = nil) throws -> String {
            let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
            var cmd = "cd \(quoted) && clear && "
            // Spawn-tuning (16 GB constraint): Throttle owns the shell, so it can cap
            // the Node/V8 heap per session before launching claude. Opt-in — a cap set
            // too low crashes claude on a big context ("JS heap out of memory"), so it
            // ships OFF (0). --max-agents is likewise opt-in (verify your Claude Code
            // version supports the flag before enabling).
            let defaults = UserDefaults.standard
            // Low-memory mode supplies a safe default cap (3072 MB) when the user hasn't
            // set one — high enough not to OOM claude on a big context, low enough to
            // stop one runaway session eating the whole 16 GB.
            var heapMB = defaults.integer(forKey: "throttleNodeHeapCapMB")
            if heapMB <= 0, defaults.bool(forKey: "throttleLowMemoryMode") { heapMB = 3072 }
            if runtime == .claudeCode, heapMB > 0 { cmd += "export NODE_OPTIONS='--max-old-space-size=\(heapMB)' && " }
            let maxAgents = defaults.integer(forKey: "throttleMaxAgents")
            let agentsFlag = runtime == .claudeCode && maxAgents > 0 ? " --max-agents \(maxAgents)" : ""
            cmd += try nativeAgentCommand(home: home, agentsFlag: agentsFlag, journal: journal ?? .shared)
        return cmd
    }

    private func nativeAgentCommand(home: URL, agentsFlag: String, journal: RemoteTransferJournal) throws -> String {
        guard runtime.usesTranscript else { return ":" }
        if let savedID = sessionId ?? resumeSessionId {
            guard !RemoteTransferReservation.contains(runtime: remoteRuntime, nativeID: savedID),
                  try journal.outstanding(runtime: remoteRuntime, nativeID: savedID) == nil else {
                throw RemoteTransferJournal.Failure.duplicateWriter
            }
            let valid = UUID(uuidString: savedID) != nil
            let exists = valid && (runtime == .claudeCode
                ? MissionRuntimeService.claudeSessionExists(
                    id: savedID, cwd: cwd, projectsRoot: home.appendingPathComponent(".claude/projects"))
                : MissionRuntimeService.codexSessionExists(
                    id: savedID, cwd: cwd, sessionsRoot: home.appendingPathComponent(".codex/sessions")))
            if exists {
                sessionId = savedID
                resumeIssue = nil
                freshClaudeSessionID = nil
                isChoosingNativeSession = false
                return runtime == .claudeCode
                    ? "claude --resume " + MissionRuntimeService.shellQuote(savedID) + agentsFlag
                    : "codex resume " + MissionRuntimeService.shellQuote(savedID)
            }
            if valid, runtime == .claudeCode, savedID == freshClaudeSessionID {
                return freshAgentCommand(agentsFlag: agentsFlag)
            }
            return try nativePickerCommand(journal: journal)
        }
        if requiresNativePicker { return try nativePickerCommand(journal: journal) }
        if runtime == .claudeCode {
            let identity = UUID().uuidString.lowercased()
            freshClaudeSessionID = identity
            sessionId = identity
        }
        resumeIssue = nil
        return freshAgentCommand(agentsFlag: agentsFlag)
    }

    private func freshAgentCommand(agentsFlag: String) -> String {
        var command = runtime.executable ?? ":"
        if runtime == .claudeCode, let identity = freshClaudeSessionID {
            command += " --session-id " + MissionRuntimeService.shellQuote(identity) + agentsFlag
        }
        if let initialPrompt, !initialPrompt.isEmpty {
            command += " " + MissionRuntimeService.shellQuote(initialPrompt)
        }
        return command
    }

    private func nativePickerCommand(journal: RemoteTransferJournal) throws -> String {
        isChoosingNativeSession = false
        guard allowsNativePicker(), !RemoteTransferReservation.contains(runtime: remoteRuntime),
              try !journal.records().contains(where: { $0.runtime == remoteRuntime && $0.holdsLocalWriter }) else {
            throw NativeLaunchFailure.pickerReserved
        }
        isChoosingNativeSession = true
        requiresNativePicker = true
        resumeIssue = runtime == .claudeCode
            ? "Saved Claude session not found locally — choose it from Claude resume."
            : "Saved Codex session not found locally — choose it from Codex resume."
        // Preserve a saved identity until the user actually chooses another one.
        return runtime == .claudeCode ? "claude --resume" : "codex resume"
    }

    @discardableResult
    func bindOwnedTranscript(_ transcript: NativeSessionBinding.Transcript) -> Bool {
        guard sessionId == nil || isChoosingNativeSession else { return false }
        let changed = sessionId != transcript.id
        sessionId = transcript.id
        freshClaudeSessionID = nil
        isChoosingNativeSession = false
        requiresNativePicker = false
        resumeIssue = nil
        return changed
    }
}

private enum NativeLaunchFailure: Error, LocalizedError {
    case pickerReserved
    var errorDescription: String? {
        """
        Stop other local sessions and return remote conversations for this runtime before \
        opening its native session picker.
        """
    }
}
