import SwiftUI

/// "Claude Code setup" — one place to see your MCP servers, skills, and plugins.
/// Read-only inventory of the agent's environment (no secrets: MCP `env` is never
/// shown). Opened from the cockpit top bar.
struct ClaudeSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var setup = ClaudeSetup()
    @State private var loading = true
    @State private var section: Section = .mcp
    // Dead-Skill audit (load-vs-use). Keyed by name; folded onto the same rows so
    // "what's loaded" and "is it earning its schema cost" live in one place.
    @State private var usageMCP: [String: DeadSkillRow] = [:]
    @State private var usageSkill: [String: DeadSkillRow] = [:]
    @State private var report: DeadSkillReport?
    // Opt-in live probe (spawns each stdio server once, reads tools/list, kills it).
    @State private var probe: [String: MCPProbeResult] = [:]
    @State private var probing = false

    enum Section: String, CaseIterable, Identifiable {
        case mcp = "MCP", skills = "Skills", plugins = "Plugins"
        var id: String { rawValue }
    }

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hair).frame(height: 1)
            picker
            Rectangle().fill(hair).frame(height: 1)
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { content.padding(16) }
            }
        }
        .frame(width: 480, height: 520)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code setup").font(.system(size: 13, weight: .semibold))
                Text("MCP servers · skills · plugins").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh")
            Button("Done") { dismiss() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var picker: some View {
        Picker("", selection: $section) {
            Text("MCP · \(setup.mcp.count)").tag(Section.mcp)
            Text("Skills · \(setup.skills.count)").tag(Section.skills)
            Text("Plugins · \(setup.plugins.count)").tag(Section.plugins)
        }
        .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .mcp: mcpList
        case .skills: skillsList
        case .plugins: pluginsList
        }
    }

    private var mcpList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if setup.mcp.isEmpty { empty("No global MCP servers configured.") }
            if let n = report?.deadCount, n > 0 { auditNote("\(n) loaded item\(n == 1 ? "" : "s") unused in \(report?.windowDays ?? 30)d — paying schema cost for nothing.") }
            if !setup.mcp.isEmpty { probeBar }
            ForEach(sortedDead(setup.mcp, by: { usageMCP[$0.name] })) { m in
                row(title: m.name, badge: m.kind, detail: m.locator, usage: usageMCP[m.name], probe: probe[m.name])
            }
            if setup.projectMCPCount > 0 {
                Text("+ \(setup.projectMCPCount) project-scoped server\(setup.projectMCPCount == 1 ? "" : "s")")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 10).padding(.horizontal, 2)
            }
        }
    }

    private var skillsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if setup.skills.isEmpty { empty("No user skills in ~/.claude/skills.") }
            ForEach(sortedDead(setup.skills, by: { usageSkill[$0.name.lowercased()] })) { s in
                row(title: s.name, badge: nil, detail: s.detail, wrapDetail: true, usage: usageSkill[s.name.lowercased()])
            }
        }
    }

    /// Stable sort that floats dead (loaded ∧ 0 uses), then least-used, to the top.
    private func sortedDead<T: Identifiable>(_ items: [T], by usage: (T) -> DeadSkillRow?) -> [T] {
        items.enumerated().sorted { a, b in
            let ua = usage(a.element), ub = usage(b.element)
            let da = ua?.isDead == true, db = ub?.isDead == true
            if da != db { return da }
            let cu = ua?.uses ?? Int.max, cv = ub?.uses ?? Int.max
            if cu != cv { return cu < cv }
            return a.offset < b.offset
        }.map(\.element)
    }

    private func auditNote(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(.secondary)
            .padding(.bottom, 8).padding(.horizontal, 2)
    }

    /// Opt-in live probe: spawns each stdio server once to read its real tool count
    /// + schema cost, then kills it. Off by default; never rewrites config.
    private var probeBar: some View {
        HStack(spacing: 8) {
            Button { runProbe() } label: {
                HStack(spacing: 5) {
                    if probing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10.5)) }
                    Text(probing ? "Probing…" : "Probe servers").font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(probing)
            Text("spawns each server once to read live tool count + schema cost")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8).padding(.horizontal, 2)
    }

    private func runProbe() {
        probing = true
        Task {
            let results = await MCPProbeService.probeAll()
            await MainActor.run {
                self.probe = Dictionary(results.map { ($0.server, $0) }) { a, _ in a }
                self.probing = false
            }
        }
    }

    private var pluginsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if setup.plugins.isEmpty { empty("No plugins installed.") }
            ForEach(setup.plugins) { p in
                row(title: p.name, badge: p.version.isEmpty ? nil : p.version, detail: p.marketplace)
            }
        }
    }

    private func row(title: String, badge: String?, detail: String, wrapDetail: Bool = false, usage: DeadSkillRow? = nil, probe: MCPProbeResult? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 0)
                // Graphite-only status — no pressure colour (colour is earned).
                if let u = usage {
                    if u.isDead {
                        Text("unused \(report?.windowDays ?? 30)d")
                            .font(.system(size: 9, weight: .semibold)).textCase(.lowercase).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(Capsule().strokeBorder(hair, lineWidth: 1))
                    } else {
                        Text("\(u.uses)×").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(wrapDetail ? 3 : 1).fixedSize(horizontal: false, vertical: wrapDetail)
            }
            if let u = usage, !u.isDead, let last = u.lastUsed {
                Text("last used \(relative(last))").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if let pr = probe { probeLine(pr) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
    }

    @ViewBuilder
    private func probeLine(_ pr: MCPProbeResult) -> some View {
        switch pr.status {
        case .healthy:
            let tok = pr.schemaTokensEst.map { " · ≈\($0 >= 1000 ? String(format: "%.1fk", Double($0)/1000) : "\($0)") tok schema" } ?? ""
            Text("probe: \(pr.toolCount ?? 0) tool\((pr.toolCount ?? 0) == 1 ? "" : "s")\(tok)")
                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary)
        case .unresponsive:
            Text("probe: no response from Throttle's environment").font(.system(size: 9.5)).foregroundStyle(.tertiary)
        case .spawnError:
            Text("probe: couldn't start from here").font(.system(size: 9.5)).foregroundStyle(.tertiary)
        case .notStdio:
            EmptyView()
        }
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 3600 { return "\(max(1, s/60))m ago" }
        if s < 86400 { return "\(s/3600)h ago" }
        return "\(s/86400)d ago"
    }

    private func empty(_ msg: String) -> some View {
        Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func reload() {
        loading = true
        Task {
            let result = await Task.detached(priority: .utility) { ClaudeSetupService.load() }.value
            await MainActor.run { self.setup = result; self.loading = false }
            // Audit is heavier (scans transcripts) — run after the inventory shows.
            let rep = await Task.detached(priority: .utility) { DeadSkillService.audit(loadout: result) }.value
            await MainActor.run {
                self.report = rep
                self.usageMCP = Dictionary(rep.rows.filter { $0.kind == .mcp }.map { ($0.name, $0) }) { a, _ in a }
                self.usageSkill = Dictionary(rep.rows.filter { $0.kind == .skill }.map { ($0.name.lowercased(), $0) }) { a, _ in a }
            }
        }
    }
}
