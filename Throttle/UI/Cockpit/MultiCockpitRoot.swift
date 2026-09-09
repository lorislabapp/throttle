import AppKit
import SwiftUI
import ThrottleShared

/// The multi-session Cockpit: several real `claude` sessions (one per project)
/// under ONE shared decision layer. The binding window + machine memory are
/// global (every session draws on the same account limits and the same Mac);
/// project + uptime are per-session. Three switchable layouts — Tabs / Rail /
/// Overview — over the same live terminal stack (Claude Design: A/B/C).
///
/// Golden rule: per-session cost/model render only when real (nil → omitted),
/// never invented. Pressure colour (orange/red) is earned only under genuine
/// cap or memory pressure.
struct MultiCockpitRoot: View {
    @Environment(AppState.self) var appState
    @State var model = MultiCockpitModel.shared   // singleton: sessions outlive the window
    @State var showSidebar = false
    @State var sidebarTab: CockpitSidebar.Tab = .audit
    @State var activeStyle = OutputStyleManager.activeName()
    @State var hoveredSession: UUID?
    @State var expandedFeed: UUID?
    @State var remoteSvc = RemoteSessionsService.shared   // edge-agent sessions in the rail
    @State var selectedRemoteID: String?  // remote session shown over the terminal area
    @State var railFilter = ""            // rail search — shown only when crowded
    @State var themePreset = CockpitTerminalTheme.current
    @State var caffeine = CaffeineService.shared   // @Observable → body tracks .active (H05)
    @State var showNotifBanner = false             // C02: notifications-denied banner
    @State var showHealth = false                  // Throttle Health panel
    @State var showActivity = false                // Work activity panel
    @State var showSetup = false                   // Claude Code setup panel
    @State var showWhatsNew = false                // What's-new / optimizations tour
    @State var showUtilityRow = false              // Dir C reveal row (chevron)
    @State var barWidth: CGFloat = 980             // drives narrow/icon-only collapse
    @State var pendingModelSwitch: PendingModelSwitch?
    @State var pendingHandoff: MissionHandoff?
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    struct PendingModelSwitch: Identifiable {
        let id = UUID()
        let tabID: UUID
        let target: String
        let impact: PromptCacheImpact
    }

    let hair = Color.primary.opacity(0.10)
    let track = Color.primary.opacity(0.08)
    var zsep: some View { Rectangle().fill(hair).frame(width: 1, height: 18) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(hair).frame(height: 1)
            globalStrip
            if let tab = model.active {
                CockpitTransitionBanner(tab: tab) { model.forgetUnconfirmedSession(tab.id) }
            }
            if model.gated { gateBanner }
            if showNotifBanner { notifDeniedBanner }
            if !model.duplicateCwds.isEmpty { duplicateBanner }
            if !model.rateLimitedSessions.isEmpty { rateLimitBanner }
            if let n = model.autoPauseCountdown { autoPauseBanner(n) } else if let hint = model.pacingHint { pacingBanner(hint) }
            if let digest = model.reentryDigest { reentryPanel(digest) }
            if let loop = model.loopSessions.first { loopBanner(loop) }
            if let leak = model.leakSessions.first { leakBanner(leak) }
            HStack(spacing: 0) {
                content
                if showSidebar {
                    Rectangle().fill(hair).frame(width: 1)
                    CockpitSidebar(tab: $sidebarTab)
                }
            }
        }
        .disabled(model.isQuitting)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            model.start(appState: appState); activeStyle = OutputStyleManager.activeName()
            if WhatsNewService.shouldShow { showWhatsNew = true }   // once per new version
        }
        .onDisappear { model.pause() }   // window close pauses the tick, never the sessions (C01)
        .onReceive(NotificationCenter.default.publisher(for: .outputStyleChanged)) { _ in
            activeStyle = OutputStyleManager.activeName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cockpitNotificationsDenied)) { _ in
            showNotifBanner = true
        }
        // Coming back is the expensive part: rebuilding the picture costs more
        // than reading it did. These two note the absence so the panel above
        // can answer "what happened while I was away" instead of restating now.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.noteAttentionLeft()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.noteAttentionReturned()
        }
        .sheet(isPresented: $showHealth) { HealthCheckView().environment(appState) }
        .sheet(isPresented: $showActivity) { WorkActivityView().environment(appState) }
        .sheet(isPresented: $showSetup) { ClaudeSetupView() }
        .sheet(isPresented: $showWhatsNew) { WhatsNewView() }
        .sheet(item: $pendingHandoff) { handoff in
            MissionHandoffSheet(
                handoff: handoff,
                sourceCache: model.sessions.first { $0.id == handoff.sourceTabID }?.promptCacheImpact
            ) { confirmed in
                Task { _ = await model.continueMission(confirmed.sourceTabID, with: confirmed) }
                pendingHandoff = nil
            } onCancel: {
                pendingHandoff = nil
            }
        }
        .alert(
            "Switch model and rebuild cache?",
            isPresented: Binding(
                get: { pendingModelSwitch != nil },
                set: { if !$0 { pendingModelSwitch = nil } }
            ),
            presenting: pendingModelSwitch
        ) { request in
            Button("Switch to \(request.target.capitalized)") { performModelSwitch(request) }
            Button("Cancel", role: .cancel) { pendingModelSwitch = nil }
        } message: { request in
            Text("This session's latest prompt is ≈\(fmtTok(request.impact.contextTokens)) input tokens. Claude Code caches per model, so switching now may rebuild it for ≈€\(String(format: "%.2f", request.impact.rebuildEUR)) (≈€\(String(format: "%.2f", request.impact.extraEURVersusWarm)) more than a warm read). Prefer switching after /clear or at the next task boundary.")
        }
    }
}
