import SwiftUI
import AppKit

/// The audit half of the cockpit, re-homed for the multi-session window: a
/// collapsible right inspector reusing the existing `CockpitViewModel` (config
/// weight, context bloat + the Surgical Trimmer, MCP health, machine detail).
/// Keeps the multi-session workspace clean while preserving the cost/health
/// audit that is Throttle's wedge.
struct CockpitAuditInspector: View {
    @Environment(AppState.self) private var appState
    @State private var vm = CockpitViewModel()
    @State private var showTrim = false
    @State private var trimAggressive = false

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                dl("AUDIT")
                Spacer()
                if vm.mcpProbing { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(hair).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    configSection
                    Rectangle().fill(hair).frame(height: 1)
                    machineSection
                    Rectangle().fill(hair).frame(height: 1)
                    mcpSection
                }
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
        .onAppear { vm.start(appState: appState) }
        .onDisappear { vm.stop() }
        .sheet(isPresented: $showTrim) { trimSheet }
    }

    // MARK: - Config weight + trimmer

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            dl("CONFIG WEIGHT")
            if let md = vm.data.config.claudeMdTokens {
                row("CLAUDE.md", "≈\(tok(md)) tok/session")
            }
            if vm.data.config.skillCount > 0 { row("Skills", "\(vm.data.config.skillCount)") }
            if vm.bloat.totalTokens > 0 {
                Button { showTrim = true; Task { await vm.scanTrim(aggressive: trimAggressive) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 10)).foregroundStyle(.orange)
                        Text("Context bloat · \(vm.bloat.images) imgs").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("≈\(tok(vm.bloat.totalTokens)) tok").font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Trim a past transcript losslessly (reversible)")
            }
            if !vm.dedup.blocks.isEmpty {
                Button {
                    let blocks = vm.dedup.blocks
                    Task { for b in blocks { await vm.hoistDedup(b) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(.orange)
                        Text("Duplicated · \(vm.dedup.projectCount) proj").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("Hoist").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accentColor)
                        Text("≈\(tok(vm.dedup.totalWasteTokens)) tok").font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help("Hoist duplicated CLAUDE.md blocks to a shared skill (backed up, reversible)")
            }
            if !vm.memory.files.isEmpty {
                actionRow("clock.badge.xmark", "Stale memory · \(vm.memory.files.count)", "≈\(tok(vm.memory.totalTokens)) tok", "Archive") {
                    let paths = vm.memory.files.map { $0.id }
                    Task { await vm.archiveMemory(paths) }
                }
            }
            if vm.skills.deadCount > 0 {
                actionRow("wrench.adjustable", "Dead skills · \(vm.skills.deadCount)", "≈\(tok(vm.skills.deadTokens)) tok", "Archive") {
                    let dead = vm.skills.skills.filter { $0.dead }
                    Task { for s in dead { await vm.archiveSkill(s.name) } }
                }
            }
            if !vm.reads.files.isEmpty || vm.firewallInstalled {
                firewallRow
            }
            if let mi = vm.memoryIndex.worst {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mi.id)])
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.ellipsis").font(.system(size: 10))
                            .foregroundStyle(mi.isOver ? Color.red : Color.orange)
                        Text(mi.isOver
                             ? "MEMORY.md · \(mi.project) · \(mi.ignoredLines) lines cut"
                             : "MEMORY.md · \(mi.project) · \(mi.pctOfCap)% of cap")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mi.isOver
                      ? "Claude Code loads only the first 200 lines / 25 KB of MEMORY.md — \(mi.ignoredLines) lines past that never load. Trim the index or move detail into linked topic files."
                      : "MEMORY.md is near the 200-line / 25 KB auto-load cap; content past it won't load. Keep the index tight.")
            }
            if vm.cache.highCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal").font(.system(size: 10)).foregroundStyle(.orange)
                    Text("Cache busters · \(vm.cache.highCount)").font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .help(vm.cache.risks.filter { $0.severity == .high }.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n\n"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var machineSection: some View {
        let m = vm.memHealth
        let tint: Color = m.critical ? .red : (m.underPressure ? .orange : .secondary)
        return VStack(alignment: .leading, spacing: 6) {
            dl("MACHINE")
            if m.totalBytes > 0 {
                row("Memory", "\(gb(m.usedBytes)) / \(gb(m.totalBytes))")
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(m.critical ? "critical" : (m.underPressure ? "warning" : "normal"))
                        .font(.system(size: 10.5)).foregroundStyle(tint)
                    Text("· \(m.claudeCount) claude · swap \(gb(m.swapUsedBytes))")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            } else {
                Text("sampling…").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder
    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                dl(vm.mcp.isEmpty ? "MCP" : "MCP · \(vm.mcp.count)")
                Spacer()
                Button { Task { await vm.probeMCP() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Probe MCP servers")
            }
            // Tool-loadout audit: too many tools degrade the agent + bloat the
            // cached prefix (≈46 vs 19 tools measured +44% accuracy / 77% faster).
            if mcpToolTotal > 40 {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10)).foregroundStyle(.orange)
                    Text("\(mcpToolTotal) tools loaded").font(.system(size: 10.5)).foregroundStyle(.orange)
                    Spacer()
                }
                .help("Large tool loadouts degrade the agent — every tool schema sits in the cached prefix, and ~46 vs 19 tools measured +44% accuracy / 77% faster. Disable the MCP servers you're not using.")
            }
            if vm.mcp.isEmpty {
                Text(vm.mcpProbing ? "probing…" : "not probed").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                ForEach(vm.mcp) { s in
                    HStack(spacing: 6) {
                        Circle().fill(mcpColor(s.status)).frame(width: 6, height: 6)
                        Text(s.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(mcpDetail(s)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Trim sheet (re-homed)

    private var trimSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trim past transcripts").font(.system(size: 15, weight: .semibold))
                    Text("Embedded screenshots are re-sent — and re-charged — every time you `--resume`. Throttle replaces them with a pointer so the lighter transcript reloads. Never deletes a message; the original is backed up. The active session is excluded.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { showTrim = false }.keyboardShortcut(.defaultAction)
            }.padding(16)
            HStack(spacing: 8) {
                Toggle(isOn: $trimAggressive) { Text("Also stub large tool outputs (>4 KB)").font(.system(size: 10.5, weight: .medium)) }
                    .toggleStyle(.checkbox)
                    .onChange(of: trimAggressive) { _, _ in Task { await vm.scanTrim(aggressive: trimAggressive) } }
                Spacer()
                if let busy = vm.trimBusy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("trimming \(busy)… runs to completion + reversible (backup kept)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let note = vm.trimNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(Color.accentColor.opacity(0.06))
            Divider()
            if vm.trimScanning && vm.trimCandidates.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…").font(.system(size: 11)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if vm.trimCandidates.isEmpty {
                Text("No trimmable past sessions.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                ScrollView { VStack(spacing: 0) { ForEach(vm.trimCandidates, id: \.sessionShort) { trimRow($0) } } }
            }
        }
        .frame(width: 560, height: 460)
    }

    private func trimRow(_ p: ContextTrimmerService.Plan) -> some View {
        let mb = Double(p.bytesSaved) / 1_048_576
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.projectLabel).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text("\(p.sessionShort) · \(p.imagesTrimmed) imgs").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
            Text(String(format: "≈%.1f MB", mb)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            if vm.trimBusy == p.sessionShort {
                ProgressView().controlSize(.mini).frame(width: 54)
            } else {
                // Disable every Trim while one runs — no confusing concurrent applies.
                Button("Trim") { Task { await vm.applyTrim(p, aggressive: trimAggressive) } }
                    .controlSize(.small).frame(width: 54).disabled(vm.trimBusy != nil)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    // MARK: - Bits

    private func dl(_ t: String) -> some View {
        Text(LocalizedStringKey(t)).font(.system(size: 8.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(label)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.primary)
        }
    }
    private func actionRow(_ icon: String, _ label: String, _ value: String, _ action: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.orange)
                Text(LocalizedStringKey(label)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(LocalizedStringKey(action)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.accentColor)
                Text(value).font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    @ViewBuilder
    private var firewallRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame").font(.system(size: 10))
                .foregroundStyle(vm.firewallInstalled ? Color.green : Color.orange)
            Text(vm.firewallInstalled ? "Read firewall · on" : "Brute reads · \(vm.reads.files.count)")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if vm.firewallBusy {
                ProgressView().controlSize(.mini)
            } else if vm.firewallInstalled {
                Button("Remove") { Task { await vm.removeFirewall() } }
                    .controlSize(.small).font(.system(size: 10.5))
            } else {
                Button("Install") { confirmInstallFirewall() }
                    .controlSize(.small).font(.system(size: 10.5))
            }
        }
    }

    private func confirmInstallFirewall() {
        let alert = NSAlert()
        alert.messageText = "Install the read firewall?"
        alert.informativeText = "Adds the mcp-local-rag server (runs via npx) to your global Claude Code config, so brute file-reads are answered with semantic snippets instead of whole files (≈30–60% fewer context tokens). Your config is backed up first and this is fully reversible. Restart Claude Code afterwards to load it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Task { await vm.installFirewall() } }
    }

    /// Total tools across probed MCP servers — the tool-loadout figure.
    private var mcpToolTotal: Int { vm.mcp.compactMap { $0.toolCount }.reduce(0, +) }

    private func tok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }
    private func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 10 ? String(format: "%.0fG", g) : String(format: "%.1fG", g)
    }
    private func mcpColor(_ st: MCPHealth.Status) -> Color {
        switch st { case .ok: return .green; case .slow, .remote: return .orange; default: return .red }
    }
    private func mcpDetail(_ s: MCPHealth) -> String {
        if let t = s.toolCount { return "\(t) tools" }
        if let l = s.latencyMs { return "\(l)ms" }
        switch s.status { case .down: return "no resp"; case .remote: return "remote"; default: return "—" }
    }
}
