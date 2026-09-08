import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {
    /// Toggle the side shell; when opening, spawn the active tab's shell so the
    /// pane isn't blank. Spawning here (not in the view's updateNSView) keeps the
    /// @Observable mutation out of the render pass.
    func toggleShell() {
        showShell.toggle()
        if showShell, let a = active, !a.isHibernated { a.ensureShellSpawned() }
    }

    /// Recompute `waitingCount` from the live tabs. Cheap (a reduce over the
    /// tabs) and called only off the render path: on a `needsInput` transition,
    /// on session add/remove/reorder, and once per tick as a backstop. Assigns
    /// only on a real change so unchanged ticks publish no `@Observable` mutation.
    func refreshWaitingCount() {
        let n = sessions.reduce(into: 0) { $0 += $1.needsInput ? 1 : 0 }
        if n != waitingCount { waitingCount = n }
    }

    /// cwds open in more than one SPAWNED tab — wasted RAM + tokens on the same
    /// project. (Cost reads identical across them because cost is per-project.)
    var duplicateCwds: Set<String> {
        let live = sessions.filter { $0.isSpawned }
        var counts: [String: Int] = [:]
        for t in live { counts[t.cwd, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// Consolidate: for each duplicated cwd, keep the most-recently-active spawned
    /// tab and hibernate the rest (resume-id preserved → wake-able, frees RAM).
    /// Never closes — nothing is lost. Doctrine: 1-click, user-initiated.
    func consolidateDuplicates() {
        for cwd in duplicateCwds {
            let dupes = sessions.filter { $0.isSpawned && $0.cwd == cwd }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            for extra in dupes.dropFirst() { Task { await hibernate(extra.id) } }
        }
    }

    /// Put a refined prompt in front of the active agent WITHOUT sending it.
    /// Returns false when there is no live terminal or the payload carries a
    /// control sequence — the caller surfaces that instead of failing silently.
    @discardableResult
    func insertDraft(_ text: String) -> Bool {
        guard let term = active?.terminal as? DroppableTerminalView else { return false }
        let payload = PromptRefinerService.insertionPayload(text)
        guard !payload.isEmpty, (try? PromptRefinerService.validate(payload)) != nil else { return false }
        term.insertComposedText(payload)
        return true
    }

    func focusSession(_ id: UUID) {
        guard let tab = sessions.first(where: { $0.id == id }) else { return }
        if tab.isHibernated {
            wake(id)
        } else {
            activeID = id
        }
    }

    /// Freeze / unfreeze every live session (SIGSTOP/SIGCONT) — the reversible
    /// pause exposed to App Intents / Shortcuts. No-op on dormant tabs.
    func pauseAll() { for session in sessions { session.pauseProcess(reason: .user) } }
    func resumeAll() { for session in sessions { session.resumeProcess() } }

    @discardableResult
    func newSession(
        projectName: String,
        cwd: String,
        runtime: AgentRuntime? = nil,
        missionID: UUID = UUID(),
        initialPrompt: String? = nil
    ) -> CockpitTab? {
        guard !isQuitting else { return nil }
        let selectedRuntime = runtime ?? runtimeForNewMission
        let kickoff = initialPrompt ?? (routingMode == .hybrid
            ? MissionRuntimeService.hybridKickoff(runtime: selectedRuntime)
            : nil)
        let s = CockpitTab(
            projectName: projectName,
            cwd: cwd,
            runtime: selectedRuntime,
            missionID: missionID,
            initialPrompt: kickoff
        )
        wire(s)
        sessions.append(s)
        recomputeSortOrder()
        activeID = s.id   // didSet → ensureSpawned
        persist()
        return s
    }

    /// Explicit one-writer handoff. The source is hibernated first, preserving its
    /// native resume id, then the target starts fresh with the canonical packet.
    @discardableResult
    func continueMission(_ sourceID: UUID, with handoff: MissionHandoff) async -> CockpitTab? {
        guard !isQuitting, let source = sessions.first(where: { $0.id == sourceID }),
              source.missionID == handoff.missionID,
              source.runtime == handoff.source,
              source.cwd == handoff.cwd,
              !source.hasRemoteOwnership,
              !source.isTransitioning,
              await hibernate(sourceID),
              sessions.contains(where: { $0.id == sourceID }) else { return nil }
        return newSession(
            projectName: source.projectName,
            cwd: source.cwd,
            runtime: handoff.target,
            missionID: source.missionID,
            initialPrompt: handoff.prompt
        )
    }

    /// Keep the source visible while stopping; only confirmed stops move focus.
    @discardableResult
    func hibernate(_ id: UUID) async -> Bool {
        guard !isQuitting, let tab = sessions.first(where: { $0.id == id }), !tab.isTransitioning,
              await tab.hibernate() else { return false }
        if activeID == id {
            activeID = sessions.first(where: { $0.id != id && $0.isSpawned && !$0.isTransitioning })?.id
        }
        persist()
        return true
    }

    func wake(_ id: UUID) {
        guard !isQuitting, let tab = sessions.first(where: { $0.id == id }) else { return }
        if tab.stopIssue != nil || tab.isTransitioning {
            activeID = id // Inspect recovery/progress; activeID's guard prevents launch.
            return
        }
        guard !tab.hasRemoteOwnership else { return }
        tab.isHibernated = false
        activeID = id
    }

    /// Re-apply the current terminal preset to every live session (theme switch).
    func restyleTerminals() {
        for tab in sessions { if let t = tab.terminal { CockpitTerminalTheme.apply(to: t, setFont: false) } }
    }

    /// Nav helpers routed to the active session's terminal.
    func jumpTurn(older: Bool) { active?.jumpTurn(older: older) }
    func scrollLive() { active?.scrollLive() }

    func close(_ id: UUID) async {
        guard !isQuitting, let tab = sessions.first(where: { $0.id == id }), !tab.isTransitioning,
              await tab.hibernate(), let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        recomputeSortOrder()
        if activeID == id { activeID = sessions.first?.id }
        persist()
    }

    /// An explicit recovery decision, separate from a successful stop. The UI
    /// states that unknown remaining processes are not terminated by forgetting.
    /// Never launch a replacement or clear the failure and silently retry it.
    func forgetUnconfirmedSession(_ id: UUID) {
        guard !isQuitting, let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].stopIssue != nil, !sessions[index].isTransitioning else { return }
        sessions.remove(at: index)
        recomputeSortOrder()
        if activeID == id { activeID = sessions.first(where: { $0.isSpawned && !$0.isTransitioning })?.id }
        persist()
    }

    func move(dragged: UUID, onto target: UUID) {
        guard dragged != target,
              let from = sessions.firstIndex(where: { $0.id == dragged }) else { return }
        let item = sessions.remove(at: from)
        let to = sessions.firstIndex(where: { $0.id == target }) ?? sessions.count
        sessions.insert(item, at: to)
        persist()
    }
}
