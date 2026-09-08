import AppKit
import SwiftTerm
import SwiftUI

/// Manages the set of cockpit sessions and the shared decision-layer data:
/// the global binding window (account-wide, from AppState) and machine memory
/// (from SystemMemoryService). The memory gate blocks opening a new session
/// when the Mac is saturated — directly serving the 16 GB constraint.
@MainActor
@Observable
final class MultiCockpitModel {
    /// Single shared instance — session lifetime must OUTLIVE the Cockpit window.
    /// Previously the model lived in the window's `@State`, so closing the window
    /// deallocated it and mass-killed all live `claude` sessions. As a singleton
    /// it survives window close: closing pauses the UI tick, never the PTYs.
    static let shared = MultiCockpitModel()
    var sortMode: SortMode = .manual { didSet { if sortMode != oldValue { recomputeSortOrder() } } }
    var activityFilter: ActivityFilter = ActivityFilter(
        rawValue: UserDefaults.standard.string(forKey: "cockpitActivityFilter") ?? ""
    ) ?? .all {
        didSet {
            guard activityFilter != oldValue else { return }
            UserDefaults.standard.set(activityFilter.rawValue, forKey: "cockpitActivityFilter")
            recomputeActivityFilter()
        }
    }

    /// Ids passing `activityFilter`; nil when the filter is `.all`. Cached and
    /// recomputed only on the tick / filter change / add-remove — same
    /// discipline as `sortedOrder`: `isActive` reads `lastActivityAt`, and a
    /// body that read it per row would invalidate the whole cockpit per byte.
    var visibleSessionIDs: Set<UUID>?
    /// Tier counts for the filter menu + header. STORED, assigned only on change,
    /// read only from the cockpit window — never from the menu-bar label.
    var liveCount = 0
    var activeCount = 0
    var routingMode: MissionRoutingMode = MissionRoutingMode(
        rawValue: UserDefaults.standard.string(forKey: "cockpitMissionRoutingMode") ?? ""
    ) ?? .automatic {
        didSet { UserDefaults.standard.set(routingMode.rawValue, forKey: "cockpitMissionRoutingMode") }
    }

    var transferRecoveryIssue: String?
    var transferRecoveryCount = 0

    var sessions: [CockpitTab] = [] { didSet { refreshWaitingCount(); recomputeActivityFilter() } }

    /// Additional launch admission for an isolated owner; lifecycle transitions
    /// still use the normal session guards and confirmed-stop path.
    @ObservationIgnored var sessionLaunchPolicy: @MainActor () -> Bool = { true }

    /// Cached display order (session ids). Recomputed only on an explicit trigger
    /// — sort-mode change, session add/remove, and the periodic tick — NOT on every
    /// `@Observable` mutation. Without this, sorting by "last activity" / cost / RAM
    /// re-sorts on every streamed byte and the rows thrash every few ms.
    var sortedOrder: [UUID] = []

    // Don't auto-spawn a HIBERNATED tab (that's the hibernate→instant-respawn
    // loop, LR-H04). wake() clears isHibernated first, so explicit wakes still spawn.
    var activeID: UUID? { didSet {
        if let selected = active, !selected.isHibernated, !selected.isTransitioning, selected.stopIssue == nil {
            selected.ensureSpawned()
            // An auto-paused tab wakes the instant you focus it: SIGCONT, zero tokens,
            // no --resume. A tab the USER paused stays frozen (their explicit intent).
            if selected.pauseReason?.resumesOnFocus == true { selected.resumeProcess() }
            if showShell { selected.ensureShellSpawned() }   // keep the split's shell live for the new tab
        }
        active?.clearAttention()
    } }
    var viewMode: ViewMode = .dashboard   // the cover page is the landing view
    /// Split-pane side shell visible? Per-tab shell (each session's own zsh in its
    /// cwd), toggled with ⌘⇧T or the toolbar button. Off by default.
    var showShell = false
    var machine: MemoryHealth = .unknown
    /// Count of sessions currently waiting on a question (header badge + the
    /// always-visible menu-bar bell).
    ///
    /// STORED, never computed. As a computed property it was read from
    /// `MenuBarLabel.body`, which subscribed the menu-bar item to `needsInput`
    /// on EVERY tab plus `sessions` itself. With 50+ restored tabs streaming PTY
    /// output, each mutation invalidated the label → `NSStatusBarButton.setImage:`
    /// → a full `NSStatusItem._adjustLength` AutoLayout solve. Invalidations
    /// arrived faster than a render completed, so SwiftUI's `UpdateGroup` never
    /// drained, the main run loop never came back, and its autorelease pool never
    /// released the AutoLayout temporaries: ~270M live allocations and 30+ GB of
    /// footprint in under three minutes, which swap-locked the whole Mac. The
    /// label now depends on exactly one Int that changes only on a real
    /// waiting-state transition.
    var waitingCount: Int = 0

    weak var appState: AppState?
    var tick: Task<Void, Never>?
    var focusObserver: NSObjectProtocol?
    var commandObserver: NSObjectProtocol?
    var pacingHint: PacingHint?
    var pcLastPct: Double?
    var pcLastAt: Date?
    let pcLowPct = 80.0            // don't nag below 80% of the binding window
    let pcEtaHorizon: TimeInterval = 30 * 60

    /// Seconds left in the cancelable arming window (nil = not armed). Drives the banner.
    var autoPauseCountdown: Int?
    var autoPauseTask: Task<Void, Never>?
    var apLastPct: Double?
    var apLastAt: Date?
    let apThresholdPct = 95.0   // matches the design's `atcap` — 97% is too late, a runaway burns ~600k tok/min
    let apEtaHorizon: TimeInterval = 5 * 60
    let apGraceSeconds = 10

    /// Cache-efficiency drop detector (hourly, notified at most once/24h): when
    /// today's prompt-cache hit rate falls ≥20 points under the 7-day baseline,
    /// something started busting the cache (hook churn, config edit, model swaps)
    /// and the plan is burning measurably faster. Complements CacheBustAnalyzer
    /// (which explains WHY) with a proactive "it's happening NOW" signal.
    var lastEffCheck = Date.distantPast
    var lastAutoHibernateAt = Date.distantPast
    var pressureObserverRegistered = false

    // Two-tier reclaim. Crowding (many spawned tabs) is a PROACTIVE proxy for
    // impending pressure, not pressure itself — so crowding-only reclaim FREEZES
    // (SIGSTOP): token burn stops, resident pages go cold (the compressor swaps
    // them cheaply), and waking is instant with NO `claude --resume` — no transcript
    // re-send, no "resuming will consume your limits" prompt, zero tokens. Only real
    // `machine.critical` pressure escalates to hibernate (kill subtree → hard-free
    // RAM), where the wake-time token cost is justified by genuinely scarce memory.
    // This is the fix for "my tabs keep dying and resuming costs tokens" when the
    // Mac is merely crowded, not actually starved (see [[kevin-mac-memory-constraint]]).
    /// CPU share of a subtree, over the sampling window, above which the session is
    /// doing real work. An idle `claude` TUI and its MCP children sit near zero; a
    /// compile, a test run or an install sit far above. Deliberately low: wrongly
    /// reclaiming a working session costs the user their work, wrongly keeping an
    /// idle one costs some RAM until the next tick.
    static let busyCPUPercent = 5.0

    /// A tool call still open after this long is presumed abandoned (claude crashed
    /// mid-tool, leaving a dangling tool_use as the transcript's last word). Without
    /// the bound, that tab would read as busy forever and never yield its RAM — worse
    /// than the bug this signal fixes, on a Mac already deep in swap.
    nonisolated static let maxToolCallProtection: TimeInterval = 30 * 60

    /// App quit waits for all captured local scopes, including side shells.
    /// Keep the working-set snapshot for the next launch; a failed stop cancels quit.
    var isQuitting = false

    // MARK: - Persistence (memory-aware: restored tabs spawn lazily via resume)

    static let persistKey = "cockpitOpenSessions"

    /// True once restore() has run or a session was added — i.e. `sessions` is the
    /// canonical working set. Until then, persisting would write garbage.
    var sessionsLoaded = false

    static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}
