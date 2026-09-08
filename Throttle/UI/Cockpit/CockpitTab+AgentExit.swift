import AppKit
import SwiftTerm
import SwiftUI

extension CockpitTab {

    /// Called when the process poll finds no agent left in this tab's subtree.
    /// Returns true when the caller should relaunch, false when input was
    /// suspended instead.
    @discardableResult
    func noteAgentExit(now: Date = Date()) -> Bool {
        recentAgentExits.append(now)
        recentAgentExits.removeAll { now.timeIntervalSince($0) > Self.agentFlapWindow }
        agentExited = true
        needsInput = false

        guard recentAgentExits.count < Self.agentFlapCount else {
            inputSuspended = true
            (terminal as? DroppableTerminalView)?.inputSuspended = true
            return false
        }
        return true
    }

    /// Re-issue the agent command into the shell that is already sitting there.
    /// No new terminal, no lost scrollback — the session resumes by id, so the
    /// conversation continues rather than restarting.
    func relaunchAgent() {
        guard allowsProcessLaunch(), !hasRemoteOwnership, !isTransitioning, stopIssue == nil,
              let view = terminal as? DroppableTerminalView, runtime.executable != nil else { return }
        let command: String
        do { command = try agentCommand() } catch {
            resumeIssue = error.localizedDescription
            return
        }
        agentExited = false
        inputSuspended = false
        view.inputSuspended = false
        spawnedAt = Date()
        view.sendProgrammatic(txt: command + "\n")
    }

    /// The user chose to keep the bare shell. Clear the flags so the pane stops
    /// claiming to be an agent and starts behaving like what it is.
    func acceptShell() {
        guard !hasRemoteOwnership, !isTransitioning, stopIssue == nil else { return }
        agentExited = false
        inputSuspended = false
        (terminal as? DroppableTerminalView)?.inputSuspended = false
        recentAgentExits.removeAll()
    }

    // MARK: - Timeline navigation (acts on this tab's live terminal)
    func jumpTurn(older: Bool) { (terminal as? DroppableTerminalView)?.scrollToTurn(older: older) }
    func scrollLive() { (terminal as? DroppableTerminalView)?.scrollToLive() }
}
