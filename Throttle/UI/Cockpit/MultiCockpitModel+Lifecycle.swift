import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    func start(appState: AppState) {
        self.appState = appState
        CockpitNotifier.shared.activate(appState: appState)
        observeSessionCommands()
        if sessions.isEmpty { restore() }   // bring back the working set (lazy)
        sessionsLoaded = true               // cockpit opened → `sessions` is canonical, safe to persist
        // React the instant pressure worsens to critical, not just on the next
        // 10–30 s tick (MEM-H01 / MEM-M03). Registered once.
        if !pressureObserverRegistered {
            pressureObserverRegistered = true
            MemoryPressureMonitor.shared.onPressureRise { [weak self] _ in self?.autoHibernateIfPressured() }
        }
        sampleMachine()
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                // Quiet mode: under memory pressure, tick 3× slower and skip the
                // heavy per-session RSS fs-walk so Throttle stops amplifying the
                // lag. The loop detector (in refreshStats) is the red line — it
                // keeps running, just less often. (NotebookLM hierarchy.)
                let quiet = MemoryPressureMonitor.shared.isQuiet
                try? await Task.sleep(for: .seconds(quiet ? 30 : 10))
                self?.sampleMachine()
                self?.refreshStats()
                self?.evaluateAutoPause()
                self?.evaluateOpusTokenCap()
                self?.evaluateCacheEfficiencyDrop()
                self?.evaluatePacing()             // soft cross-session pacing tier below auto-pause
                self?.autoHibernateIfPressured()   // MEM-H01: reclaim idle-session RAM under critical pressure
                self?.refreshWaitingCount()        // backstop for any transition the didSet missed
                self?.detectAgentExit()            // agent gone but its shell still taking keystrokes
                if !quiet { self?.sampleSessionRAM() }
            }
        }
    }

    private func observeSessionCommands() {
        if focusObserver == nil {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .cockpitFocusSession, object: nil, queue: .main) { [weak self] note in
                guard let str = note.userInfo?["tab"] as? String, let id = UUID(uuidString: str) else { return }
                Task { @MainActor in
                    guard let self, self.sessions.contains(where: { $0.id == id }) else { return }
                    self.activeID = id
                    if self.viewMode == .mission { self.viewMode = .rail }
                }
            }
        }
        if commandObserver == nil {
            // Cross-process pause/resume from App Intents / Shortcuts (ThrottleCommandChannel).
            commandObserver = NotificationCenter.default.addObserver(
                forName: .throttleCommand, object: nil, queue: .main) { [weak self] note in
                guard let action = note.userInfo?["action"] as? String else { return }
                Task { @MainActor in
                    guard let self else { return }
                    if action == ThrottleAction.pauseAll.rawValue {
                        self.pauseAll()
                    } else if action == ThrottleAction.resumeAll.rawValue {
                        self.resumeAll()
                    }
                }
            }
        }
    }

    /// Window closed (NOT app quit): pause the sampling tick + persist, but KEEP
    /// every session running in the background. Reopening the window re-arms via
    /// start(). This is the half of the C01 fix that stops window-close from
    /// killing live sessions.
    func pause() {
        persist()
        tick?.cancel(); tick = nil
    }

    func stop() async -> Bool {
        guard !isQuitting else { return false }
        let snapshot = sessions
        persist()
        isQuitting = true
        var completed = false
        defer { if !completed { isQuitting = false } }
        for tab in snapshot {
            guard !tab.isTransitioning, await tab.hibernate() else { return false }
        }
        guard Set(snapshot.map(\.id)) == Set(sessions.map(\.id)),
              sessions.allSatisfy({ !$0.isSpawned && $0.shellTerminal == nil && !$0.isTransitioning })
        else { return false }
        tick?.cancel(); tick = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        if let commandObserver {
            NotificationCenter.default.removeObserver(commandObserver); self.commandObserver = nil
        }
        sessions.removeAll()
        completed = true
        return true
    }

    /// Wire a tab's question callback: a question in a HIDDEN session raises a
    /// local notification (you may be in another window); the active session
    /// already shows the prompt, so no notification — just the in-app badge.
    func wire(_ tab: CockpitTab) {
        tab.allowsProcessLaunch = { [weak self, weak tab] in
            guard let self, let tab, !self.isQuitting, self.sessionLaunchPolicy() else { return false }
            if let nativeID = tab.sessionId, self.sessions.contains(where: {
                $0 !== tab && $0.runtime == tab.runtime && $0.isSpawned
                    && ($0.isChoosingNativeSession || $0.sessionId?.caseInsensitiveCompare(nativeID) == .orderedSame)
            }) {
                tab.resumeIssue =
                    "Another local tab is using or choosing this native conversation. Stop it before resuming."
                return false
            }
            return true
        }
        tab.allowsNativePicker = { [weak self, weak tab] in
            guard let self, let tab, !self.isQuitting else { return false }
            return !self.sessions.contains { $0 !== tab && $0.runtime == tab.runtime && $0.isSpawned }
        }
        tab.onQuestion = { [weak self] tab, q in
            guard let self, tab.id != self.activeID else { return }
            CockpitNotifier.shared.notifyWaiting(project: tab.projectName, question: q, tabID: tab.id)
        }
        tab.onRateLimited = { tab in
            CockpitNotifier.shared.notifyRateLimited(
                project: tab.projectName, until: tab.rateLimitedUntil, tabID: tab.id)
        }
    }
}
