import SwiftUI

/// The cockpit: Throttle's decision layer wrapped around a real `claude`
/// terminal. The terminal is a commodity container; the product is the
/// instrument — the binding number, an honest forecast, the session cost, and
/// the local config cost-sources Anthropic's own dashboard never surfaces.
///
/// Two density levels: **full** (Strip A + collapsible Rail B) and **compact**
/// (an ambient HUD over a full-bleed terminal). Every value is real or hidden —
/// never a faked number (see the golden rule in UI-SPEC-cockpit.md).
struct CockpitWindowRoot: View {
    @Environment(AppState.self) private var appState
    @State private var vm = CockpitViewModel()
    @State private var terminalController = CockpitTerminalController()
    @State private var railOpen = true
    @State private var compact = false
    @State private var showingDedup = false
    @State private var showingMemory = false
    @State private var showingCache = false

    var body: some View {
        Group {
            if compact { compactLayout } else { fullLayout }
        }
        .onAppear { vm.start(appState: appState) }
        .onDisappear { vm.stop() }
        .sheet(isPresented: $showingDedup) { dedupSheet }
        .sheet(isPresented: $showingMemory) { memorySheet }
        .sheet(isPresented: $showingCache) { cacheSheet }
    }

    // MARK: - Cache hygiene sheet

    private var cacheSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompt-cache hygiene").font(.system(size: 15, weight: .semibold))
                    Text("Cached input tokens bill at ~10% of normal. A hook that injects changing content into the cached prefix invalidates the cache — you pay full input price every session. Keep injected text byte-stable, or move the varying part out of the prefix.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showingCache = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView { VStack(spacing: 0) { ForEach(vm.cache.risks) { cacheRow($0) } } }
        }
        .frame(width: 580, height: 460)
    }

    private func cacheRow(_ r: CacheRisk) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(r.severity == .high ? Color.orange : Color.primary.opacity(0.25))
                .frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                Text(r.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(r.severity == .high ? "busts cache" : "ok")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(r.severity == .high ? Color.orange : Color.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    // MARK: - Stale memory sheet

    private var memorySheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stale memory").font(.system(size: 15, weight: .semibold))
                    Text("Files in ~/.claude/projects/*/memory/ unused 30+ days — still reloaded into context every session. Reveal and delete the ones you no longer need.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showingMemory = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView { VStack(spacing: 0) { ForEach(vm.memory.files) { memoryRow($0) } } }
            Divider()
            HStack {
                Text("≈\(fmtTokens(vm.memory.totalTokens)) tokens reloaded every session")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 560, height: 480)
    }

    private func memoryRow(_ m: StaleMemory) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text("\(m.project) · \(m.ageDays)d unused").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text("≈\(fmtTokens(m.tokens)) tok").font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.id)])
            } label: {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    // MARK: - Dedup review sheet

    private var dedupSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Duplicated context").font(.system(size: 15, weight: .semibold))
                    Text("Same CLAUDE.md content across \(vm.dedup.projectCount) projects — paid for every session of each. Hoist to a shared skill in ~/.claude/skills/ to load it on-demand instead.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showingDedup = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.dedup.blocks) { dedupRow($0) }
                }
            }
            Divider()
            HStack {
                Text("≈\(fmtTokens(vm.dedup.totalWasteTokens)) tokens of duplication across your projects")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 580, height: 520)
    }

    private func dedupRow(_ b: DuplicatedBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(b.projects.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 6)
                Text("≈\(fmtTokens(b.wasteTokens)) tok").font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(b.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).help("Copy this block")
            }
            Text(b.text)
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(4).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    // MARK: - Full layout

    private var fullLayout: some View {
        VStack(spacing: 0) {
            identityBar
            hairline
            if let b = binding, b.pct >= 0.80 {
                atLimitBanner(b); hairline
            }
            stripA
            hairline
            HStack(spacing: 0) {
                terminal
                if railOpen {
                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
                    railB
                }
            }
        }
    }

    private var compactLayout: some View {
        ZStack(alignment: .topTrailing) {
            terminal
            if let b = binding { hudChip(b).padding(12) }
            compactExit.padding(12)
        }
    }

    private var terminal: some View {
        CockpitTerminalView(controller: terminalController)
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
    }

    // MARK: - Identity bar

    private var identityBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.85))
            Text("Throttle Cockpit").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            modelMenu
            appState.isPro ? pill("PRO") : pill("FREE")
            if isExact { exactPill }
            iconButton("rectangle.righthalf.inset.filled", on: railOpen) { railOpen.toggle() }
                .help("Toggle inspector rail")
            iconButton("arrow.down.right.and.arrow.up.left", on: false) { compact = true }
                .help("Compact mode")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var compactExit: some View {
        Button { compact = false } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .padding(7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Exit compact mode")
    }

    private func iconButton(_ name: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pill(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy)).tracking(0.06)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(.secondary)
    }

    private var exactPill: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 4, height: 4)
            Text("EXACT")
        }
        .font(.system(size: 9, weight: .heavy)).tracking(0.06)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Model selector (passthrough to `/model`)

    private var modelMenu: some View {
        Menu {
            ForEach([ModelTier.opus, .sonnet, .haiku], id: \.self) { t in
                Button { terminalController.run("/model \(modelCmd(t))") } label: {
                    Text(modelMenuLabel(t))
                }
                .disabled(vm.data.currentModelTier == t)
            }
            Divider()
            Text("Types /model into the terminal").font(.system(size: 10))
        } label: {
            HStack(spacing: 3) {
                Text(currentModelName).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch the session model (Claude Code applies it)")
    }

    private var currentModelName: String {
        guard let tier = vm.data.currentModelTier else { return "Model" }
        if tier == .other, let name = vm.data.currentModelName { return name }
        return tierName(tier)
    }

    private func modelCmd(_ t: ModelTier) -> String {
        switch t {
        case .opus: return "opus"; case .sonnet: return "sonnet"
        case .haiku: return "haiku"; case .other: return "default"
        }
    }

    private func modelMenuLabel(_ t: ModelTier) -> String {
        let name = tierName(t)
        guard let cur = vm.data.currentModelTier, cur != t else { return "\(name) (current)" }
        let factor = outputRate(cur) / outputRate(t)
        if factor >= 1.5 { return "\(name) · ~\(Int(factor.rounded()))× cheaper" }
        if factor <= 0.67 { return "\(name) · ~\(Int((1 / factor).rounded()))× pricier" }
        return name
    }

    /// Output €/M rate per tier, from the shared PlanAdvisor table (no hardcoding).
    private func outputRate(_ t: ModelTier) -> Double {
        switch t {
        case .opus:   return PlanAdvisor.opus47.outputPerM
        case .sonnet: return PlanAdvisor.sonnet46.outputPerM
        case .haiku:  return PlanAdvisor.haiku45.outputPerM
        case .other:  return PlanAdvisor.sonnet46.outputPerM
        }
    }

    // MARK: - Strip A (decision)

    private var stripA: some View {
        HStack(alignment: .center, spacing: 0) {
            bindingCell
            if let f = forecast {
                stripDivider; forecastCell(f)
            }
            if vm.data.sessionTokens != nil {
                stripDivider; sessionCell
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private var stripDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1, height: 44)
    }

    @ViewBuilder
    private var bindingCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel("BINDING NOW")
            if let b = binding {
                bindingHero(b)
                headroomBar(b.pct, degraded: b.degraded, width: 150)
            } else {
                Text(verbatim: "—").font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func bindingHero(_ b: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            heroNumber(b)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(b.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.primary)
                    Text(b.sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(b.resetText).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private func heroNumber(_ b: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if b.degraded {
                Text(verbatim: "≈").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            Text("\(Int((b.pct * 100).rounded()))")
                .font(.system(size: 30, weight: .medium).monospacedDigit()).tracking(-0.6)
            Text(verbatim: "%").font(.system(size: 15)).opacity(0.55)
        }
        .foregroundStyle(b.degraded ? Color.secondary : pressureColor(b.pct))
    }

    private func forecastCell(_ f: Forecast) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel("FORECAST")
            HStack(spacing: 7) {
                Image(systemName: f.tone == .neutral ? "clock" : "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(forecastTint(f.tone))
                Text(f.text).font(.system(size: 12)).foregroundStyle(.secondary)
                estTag
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(minWidth: 150, alignment: .leading)
    }

    private var sessionCell: some View {
        VStack(alignment: .leading, spacing: 7) {
            dlLabel(vm.data.currentSessionProject.map { "LATEST · \($0.uppercased())" } ?? "LATEST SESSION")
            HStack(spacing: 5) {
                Text(fmtTokens(vm.data.sessionTokens ?? 0))
                    .font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.primary)
                Text("tok").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if let c = vm.data.sessionCostEUR {
                    Text("· ≈\(fmtEUR(c))").font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let all = vm.data.allTimeCostEUR {
                Text("API value · ≈\(fmtEUR(all)) all-time")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                Text("at API rates").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: - Rail B (Environment & cost sources)

    private var railB: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                railSection("OTHER WINDOWS") { otherWindowsList }
                railHairline
                if !vm.data.modelSplit.isEmpty {
                    railSection("MODEL SPLIT") { modelSplitView }
                    railHairline
                }
                if vm.data.config.hasAnything {
                    railSection("CONFIG WEIGHT") { configWeightView }
                    railHairline
                }
                mcpSection
                if !vm.data.sessions.isEmpty {
                    railSection("RECENT SESSIONS") { sessionsView }
                }
            }
        }
        .frame(width: 232)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sessionsView: some View {
        VStack(spacing: 10) {
            ForEach(vm.data.sessions) { s in
                sessionRow(s)
            }
        }
    }

    private func sessionRow(_ s: CockpitSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if s.isCurrent {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                }
                Text(s.project ?? "Session").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 4)
                Button { terminalController.run(resumeCommand(s)) } label: {
                    Text("Resume").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.projectPath.map { "cd \($0) && claude --resume" } ?? "claude --resume (no project path resolved)")
                .disabled(s.isCurrent)
                .opacity(s.isCurrent ? 0.35 : 1)
            }
            HStack(spacing: 5) {
                Text(relativeTime(s.lastActivity)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Text("·").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Text(fmtTokens(s.weightedTokens)).font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                if let c = s.costEUR {
                    Text("· ≈\(fmtEUR(c))").font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let t = s.topTier {
                    Text("· \(tierName(t))").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Resume must run from the session's project directory or `claude --resume`
    /// can't find it — so cd there first when we resolved the path.
    private func resumeCommand(_ s: CockpitSession) -> String {
        if let p = s.projectPath {
            return "cd '\(p.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(s.id)"
        }
        return "claude --resume \(s.id)"
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    private var railHairline: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
    }

    private func railSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dlLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var otherWindowsList: some View {
        VStack(spacing: 7) {
            ForEach(others, id: \.kind) { r in
                HStack(spacing: 9) {
                    Text("\(r.name) \(r.sub)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    miniBar(r.pct, degraded: r.degraded)
                    Text("\(r.degraded ? "≈" : "")\(Int((r.pct * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(r.degraded ? Color.secondary : .primary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var modelSplitView: some View {
        let slices = vm.data.modelSplit.sorted { $0.weightedTokens > $1.weightedTokens }
        let total = max(1, slices.reduce(0) { $0 + $1.weightedTokens })
        let top = slices.first
        let topPct = top.map { Int((Double($0.weightedTokens) / Double(total) * 100).rounded()) } ?? 0
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { idx, s in
                        Capsule().fill(Color.primary.opacity(splitOpacity(idx)))
                            .frame(width: max(2, geo.size.width * Double(s.weightedTokens) / Double(total)))
                    }
                }
            }
            .frame(height: 6)
            if let top {
                let label = (top.tier == .other ? (vm.data.currentModelName ?? "Other") : tierName(top.tier))
                HStack(spacing: 4) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                    Text("\(topPct)%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            // Nudge: most weight on premium models (Opus / Fable etc.) → Sonnet is far cheaper.
            let premium = slices.filter { $0.tier != .sonnet && $0.tier != .haiku }
                .reduce(0) { $0 + $1.weightedTokens }
            let premiumPct = Int(Double(premium) / Double(total) * 100)
            if premiumPct > 70 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    Text("\(premiumPct)% premium · Sonnet ~5× cheaper")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { terminalController.run("/model sonnet") } label: {
                        Text("Switch").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Types /model sonnet into the terminal")
                }
            }
        }
    }

    private var configWeightView: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let md = vm.data.config.claudeMdTokens {
                configRow("CLAUDE.md", value: "≈\(fmtTokens(md)) tok / session")
            }
            if vm.data.config.skillCount > 0 {
                configRow("Skills", value: "\(vm.data.config.skillCount)")
            }
            if !vm.dedup.blocks.isEmpty {
                optimizeRow("doc.on.doc", "Duplicated × \(vm.dedup.projectCount) projects",
                            "≈\(fmtTokens(vm.dedup.totalWasteTokens)) tok",
                            help: "Review duplicated CLAUDE.md content you can hoist to a shared skill") {
                    showingDedup = true
                }
            }
            if !vm.memory.files.isEmpty {
                optimizeRow("clock.badge.xmark", "Stale memory · \(vm.memory.files.count) files",
                            "≈\(fmtTokens(vm.memory.totalTokens)) tok",
                            help: "Memory files unused 30+ days — still reloaded every session") {
                    showingMemory = true
                }
            }
            if vm.cache.highCount > 0 {
                optimizeRow("bolt.horizontal.circle", "Cache busters · \(vm.cache.highCount)",
                            "≤10× input",
                            help: "Hooks inject changing content into the cached prompt prefix — busting the 90%-cheaper cache") {
                    showingCache = true
                }
            }
        }
    }

    private func optimizeRow(_ icon: String, _ label: String, _ value: String,
                             help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.orange)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder
    private var mcpSection: some View {
        if !vm.mcp.isEmpty || vm.mcpProbing {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    dlLabel(vm.mcp.isEmpty ? "MCP" : "MCP · \(vm.mcp.count)")
                    Spacer(minLength: 4)
                    if vm.mcpProbing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { Task { await vm.probeMCP() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Probe MCP servers (list_tools)")
                    }
                }
                if vm.mcp.isEmpty && vm.mcpProbing {
                    Text("probing…").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    mcpRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            railHairline
        }
    }

    private var mcpRows: some View {
        VStack(spacing: 6) {
            ForEach(vm.mcp) { m in
                HStack(spacing: 8) {
                    Circle().fill(mcpColor(m.status)).frame(width: 5, height: 5)
                    Text(m.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mcpDetail(m)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func mcpColor(_ s: MCPHealth.Status) -> Color {
        switch s {
        case .ok:      return .green
        case .slow:    return .orange
        case .down:    return Color.primary.opacity(0.3)   // "no resp" — may be cold-start/our-spawn limit, not necessarily broken
        case .remote:  return Color.accentColor.opacity(0.6)
        case .unknown: return Color.primary.opacity(0.25)
        }
    }

    private func mcpDetail(_ m: MCPHealth) -> String {
        switch m.status {
        case .ok, .slow:
            let tools = m.toolCount.map { "\($0) tools" } ?? ""
            let ms = m.latencyMs.map { " · \($0)ms" } ?? ""
            return tools + ms
        case .down:    return "no resp"
        case .remote:  return m.latencyMs.map { "remote · \($0)ms" } ?? "remote"
        case .unknown: return "—"
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.primary)
        }
    }

    // MARK: - HUD (compact)

    private func hudChip(_ b: Reading) -> some View {
        let crit = b.pct >= 0.95, warn = b.pct >= 0.80
        return VStack(alignment: .leading, spacing: 7) {
            Text("\(b.name) \(b.sub)".uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if b.degraded { Text(verbatim: "≈").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)) }
                Text("\(Int((b.pct * 100).rounded()))")
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                Text(verbatim: "%").font(.system(size: 11)).opacity(0.55)
            }
            .foregroundStyle(hudInk(b.pct))
            Capsule().fill(Color.white.opacity(0.14)).frame(width: 140, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(hudInk(b.pct)).frame(width: max(3, 140 * min(1, b.pct)), height: 4)
                }
            if warn, let f = forecast {
                Text(f.text).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            if let tok = vm.data.sessionTokens {
                Text("\(fmtTokens(tok)) tok\(vm.data.sessionCostEUR.map { " · ≈\(fmtEUR($0))" } ?? "") session")
                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(crit || warn ? 13 : 11)
        .frame(width: crit ? 196 : (warn ? 188 : 150), alignment: .leading)
        .environment(\.colorScheme, .dark)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(hudInk(b.pct).opacity(crit || warn ? 0.4 : 0.12), lineWidth: 1))
    }

    private func hudInk(_ pct: Double) -> Color {
        switch pct {
        case ..<0.80: return .white
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    // MARK: - Small parts

    private func dlLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
    }

    private var estTag: some View {
        Text("est").font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .foregroundStyle(.tertiary)
    }

    private func atLimitBanner(_ b: Reading) -> some View {
        let crit = b.pct >= 0.95
        let tint: Color = crit ? .red : .orange
        let text = crit
            ? "\(b.name) \(b.sub) is over its cap — finish up or switch to Sonnet."
            : "Approaching the \(b.name) \(b.sub) cap — ease off or switch to Sonnet."
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(tint)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if vm.data.currentModelTier == .opus {
                Button { terminalController.run("/model sonnet") } label: {
                    Text("Switch to Sonnet").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.accentColor).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Types /model sonnet into the terminal")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
    }

    private func headroomBar(_ pct: Double, degraded: Bool, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.10)).frame(width: width, height: 5)
            tick(at: 0.80, width: width)
            tick(at: 0.95, width: width)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, width * min(1, pct)), height: 5)
        }
        .frame(width: width, height: 5)
    }

    private func tick(at frac: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 5).offset(x: width * frac)
    }

    private func miniBar(_ pct: Double, degraded: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12)).frame(width: 44, height: 4)
            Capsule().fill(degraded ? Color.secondary : pressureColor(pct))
                .frame(width: max(3, 44 * min(1, pct)), height: 4)
        }
    }

    private func pressureColor(_ pct: Double) -> Color {
        switch pct {
        case ..<0.80: return Color.primary.opacity(0.55)
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private func forecastTint(_ tone: Forecast.Tone) -> Color {
        switch tone {
        case .neutral: return Color.primary.opacity(0.45)
        case .warn:    return .orange
        case .crit:    return .red
        }
    }

    private func splitOpacity(_ idx: Int) -> Double {
        switch idx { case 0: return 0.70; case 1: return 0.40; case 2: return 0.18; default: return 0.10 }
    }

    private func tierName(_ t: ModelTier) -> String {
        switch t {
        case .opus: return "Opus"; case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"; case .other: return "Other"
        }
    }

    // MARK: - Forecast (honest extrapolation; always an estimate)

    struct Forecast {
        enum Tone { case neutral, warn, crit }
        let minutes: Double
        let msgs: Int?
        let tone: Tone
        var text: String {
            let t = Self.fmtMinutes(minutes)
            if let m = msgs, m >= 0 { return "≈\(t) · ≈\(m) msgs to cap" }
            return "≈\(t) to cap"
        }
        static func fmtMinutes(_ m: Double) -> String {
            let mins = max(0, Int(m.rounded()))
            if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
            return "\(mins)m"
        }
    }

    private var forecast: Forecast? {
        guard let b = binding, let cap = b.capTokens, cap > 0,
              let burn = vm.data.burn, burn.tokensPerMinute > 0 else { return nil }
        let remaining = Double(cap) * (1 - b.pct)
        guard remaining > 0 else { return nil }   // at/over cap → the banner speaks instead
        let minutes = remaining / burn.tokensPerMinute
        // If you'll hit the rolling-window reset before the cap, there's nothing
        // to warn about — hide it rather than show a useless multi-day countdown.
        let resetMinutes = Double(b.resetSeconds) / 60.0
        guard resetMinutes <= 0 || minutes < resetMinutes else { return nil }
        // Only show a messages-left figure when it's small enough to be useful.
        let rawMsgs = vm.data.avgTokensPerMessage.map { Int((remaining / $0).rounded()) }
        let msgs = (rawMsgs ?? .max) <= 500 ? rawMsgs : nil
        let tone: Forecast.Tone = b.pct >= 0.95 ? .crit : (b.pct >= 0.80 ? .warn : .neutral)
        return Forecast(minutes: minutes, msgs: msgs, tone: tone)
    }

    // MARK: - Readings (exact when fresh, else local estimate)

    private struct Reading {
        let kind: WindowKind
        let name: String
        let sub: String
        let pct: Double
        let capTokens: Int?
        let resetSeconds: Int64
        let resetText: String
        let degraded: Bool
    }

    private var isExact: Bool { appState.exactSnapshot?.isFresh() == true }

    private var readings: [Reading] {
        [
            reading(.session5h, name: "Session", sub: "5h",
                    local: appState.snapshot.session5h, exact: appState.exactSnapshot?.fiveHour),
            reading(.weeklyAll, name: "Weekly", sub: "all models",
                    local: appState.snapshot.weeklyAll, exact: appState.exactSnapshot?.sevenDay),
            reading(.weeklySonnet, name: "Weekly", sub: "Sonnet",
                    local: appState.snapshot.weeklySonnet, exact: appState.exactSnapshot?.sevenDaySonnet),
        ].compactMap { $0 }
    }

    private var binding: Reading? { readings.max { $0.pct < $1.pct } }

    private var others: [Reading] {
        guard let b = binding else { return readings }
        return readings.filter { $0.kind != b.kind }
    }

    private func reading(
        _ kind: WindowKind, name: String, sub: String,
        local: UsageSnapshot.Window, exact: ExactSnapshot.Window?
    ) -> Reading? {
        let degraded = !isExact
        let pct: Double?
        let resetSeconds: Int64
        if isExact, let exact {
            pct = Double(exact.utilization) / 100.0
            resetSeconds = exact.resetsAt.map { Int64(max(0, $0.timeIntervalSinceNow)) } ?? local.resetInSeconds
        } else {
            pct = local.percentUsed
            resetSeconds = local.resetInSeconds
        }
        guard let pct else { return nil }
        return Reading(kind: kind, name: name, sub: sub, pct: pct, capTokens: local.capTokens,
                       resetSeconds: resetSeconds,
                       resetText: "resets in \(formatReset(resetSeconds))", degraded: degraded)
    }

    private func formatReset(_ seconds: Int64) -> String {
        let s = max(0, seconds), h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1000)k" }
        return "\(n)"
    }

    private func fmtEUR(_ v: Double) -> String {
        if v >= 100_000 { return String(format: "€%.0fk", v / 1000) }  // €150k
        if v >= 1_000   { return String(format: "€%.0f", v) }          // €1081
        return String(format: "€%.2f", v)                              // €7.87
    }
}
