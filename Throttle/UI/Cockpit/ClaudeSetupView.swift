import SwiftUI

/// "Claude Code setup" — one place to see your MCP servers, skills, and plugins.
/// Read-only inventory of the agent's environment (no secrets: MCP `env` is never
/// shown). Opened from the cockpit top bar.
struct ClaudeSetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var setup = ClaudeSetup()
    @State private var loading = true
    @State private var section: Section = .mcp

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
            ForEach(setup.mcp) { m in
                row(title: m.name, badge: m.kind, detail: m.locator)
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
            ForEach(setup.skills) { s in row(title: s.name, badge: nil, detail: s.detail, wrapDetail: true) }
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

    private func row(title: String, badge: String?, detail: String, wrapDetail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let badge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(wrapDetail ? 3 : 1).fixedSize(horizontal: false, vertical: wrapDetail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
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
        }
    }
}
