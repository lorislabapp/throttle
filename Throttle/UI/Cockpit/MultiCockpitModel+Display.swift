import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {

    enum ViewMode: String, CaseIterable, Identifiable {
        case dashboard, rail, tabs, mission, portfolio, plan
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dashboard: return String(localized: "Dashboard")
            case .tabs:      return String(localized: "Tabs")
            case .rail:      return String(localized: "Rail")
            case .mission:   return String(localized: "Overview")
            case .portfolio, .plan: return self == .plan ? String(localized: "Plan") : String(localized: "Portfolio")
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case manual, recent, cost, ram, name, waiting
        var id: String { rawValue }
        var label: String {
            switch self {
            case .manual:  return String(localized: "Manual order")
            case .recent:  return String(localized: "Last activity")
            case .cost:    return String(localized: "Cost")
            case .ram:     return String(localized: "Memory")
            case .name:    return String(localized: "Name")
            case .waiting: return String(localized: "Waiting first")
            }
        }
    }

    /// Rail / tab-bar activity filter. Two tiers the user can tell apart: LIVE
    /// (a process runs) and ACTIVE (it is doing something or waiting on them).
    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all, live, active
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:    return String(localized: "All sessions")
            case .live:   return String(localized: "Live sessions")
            case .active: return String(localized: "Active sessions")
            }
        }
        nonisolated func passes(isLive: Bool, isActive: Bool) -> Bool {
            switch self {
            case .all:    return true
            case .live:   return isLive
            case .active: return isActive
            }
        }
    }

    func recomputeActivityFilter(now: Date = Date()) {
        var live = 0, active = 0
        var ids = Set<UUID>()
        for tab in sessions {
            let spawned = tab.isSpawned, busy = tab.isActive(now: now)
            if spawned { live += 1 }
            if busy { active += 1 }
            if activityFilter.passes(isLive: spawned, isActive: busy) { ids.insert(tab.id) }
        }
        if live != liveCount { liveCount = live }
        if active != activeCount { activeCount = active }
        let next: Set<UUID>? = activityFilter == .all ? nil : ids
        if next != visibleSessionIDs { visibleSessionIDs = next }
    }

    /// `displaySessions` after the activity filter. The selected tab is pinned:
    /// it is what the terminal shows, so the list must not deny it exists.
    var visibleSessions: [CockpitTab] {
        Self.visibleSessions(displaySessions, visibleIDs: visibleSessionIDs, pinned: activeID)
    }

    static func visibleSessions(_ sessions: [CockpitTab], visibleIDs: Set<UUID>?, pinned: UUID?) -> [CockpitTab] {
        guard let visibleIDs else { return sessions }
        return sessions.filter { visibleIDs.contains($0.id) || $0.id == pinned }
    }

    var runtimeForNewMission: AgentRuntime {
        if routingMode == .hybrid {
            return MissionRuntimeService.resolveHybrid(
                claudeRateLimited: !rateLimitedSessions.isEmpty,
                claudeSessions: sessions.filter { $0.runtime == .claudeCode }.count,
                codexSessions: sessions.filter { $0.runtime == .codex }.count
            )
        }
        return MissionRuntimeService.resolve(routingMode, claudeRateLimited: !rateLimitedSessions.isEmpty)
    }

    /// Sessions in display order. `.manual` keeps the drag order; other modes map
    /// the live `sessions` onto the cached `sortedOrder` (stable between recomputes;
    /// ids not yet ranked fall to the end in their current order).
    var displaySessions: [CockpitTab] {
        guard sortMode != .manual else { return sessions }
        var rank: [UUID: Int] = [:]
        for (i, id) in sortedOrder.enumerated() { rank[id] = i }
        return sessions.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    /// Snapshot a fresh ordering for the current `sortMode` into `sortedOrder`.
    func recomputeSortOrder() {
        let ordered: [CockpitTab]
        switch sortMode {
        case .manual:  ordered = sessions
        case .recent:  ordered = sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        case .cost:    ordered = sessions.sorted { ($0.eur ?? -1) > ($1.eur ?? -1) }
        case .ram:     ordered = sessions.sorted { $0.ramBytes > $1.ramBytes }
        case .name:    ordered = sessions.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
        case .waiting: ordered = sessions.sorted {
            ($0.needsInput ? 1 : 0) != ($1.needsInput ? 1 : 0)
                ? ($0.needsInput ? 1 : 0) > ($1.needsInput ? 1 : 0)
                : $0.lastActivityAt > $1.lastActivityAt
        }
        }
        sortedOrder = ordered.map(\.id)
    }

    var active: CockpitTab? { sessions.first { $0.id == activeID } ?? sessions.first }

    /// Sessions currently blocked by the account cap, soonest-reset first.
    var rateLimitedSessions: [CockpitTab] {
        sessions.filter { $0.isRateLimited }
            .sorted { ($0.rateLimitedUntil ?? .distantFuture) < ($1.rateLimitedUntil ?? .distantFuture) }
    }
    /// The earliest reset among blocked sessions (for the aggregate banner).
    var soonestRateLimitReset: Date? { rateLimitedSessions.first?.rateLimitedUntil }

    /// Sessions the loop detector flagged as cycling without progress.
    var loopSessions: [CockpitTab] { sessions.filter { $0.loopSignal != nil } }
    /// Spawned sessions whose subtree RSS ballooned past the leak threshold (#4953).
    var leakSessions: [CockpitTab] { sessions.filter { $0.leakSuspected && $0.isSpawned } }
}
