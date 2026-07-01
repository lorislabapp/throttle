import AppKit
import SwiftUI

/// Full MCP-server manager: list every server across all three Claude Code
/// scopes (Global / Project-local / Project .mcp.json), enable/disable, move
/// between scopes, add, and delete. Drives `MCPConfigService`, which backs up
/// each touched file before writing.
struct MCPManagerSheet: View {
    var onDone: () -> Void = {}
    @State private var entries: [MCPConfigService.Entry] = []
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if adding {
                    MCPAddEditor { didSave in
                        adding = false
                        if didSave { reload() }
                    }
                } else {
                    listView
                }
            }
        }
        .frame(width: 500, height: 560)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Text(adding ? "Add MCP server" : "MCP servers")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if !adding {
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
            }
            Button("Done") { onDone() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var listView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Every MCP server Claude Code sees, across scopes. Move a server between Global, Project-local, and the shareable .mcp.json. Throttle backs up each file before any change.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }

                ForEach(groupedScopes, id: \.0.key) { scope, rows in
                    scopeHeader(scope)
                    ForEach(rows) { entry in
                        row(entry)
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    }
                }

                if entries.isEmpty {
                    Text("No MCP servers configured.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(24)
                }
            }
        }
    }

    private func scopeHeader(_ scope: MCPConfigService.Scope) -> some View {
        HStack(spacing: 5) {
            Text(scope.label.uppercased())
                .font(.system(size: 9.5, weight: .heavy)).tracking(0.4)
                .foregroundStyle(.secondary)
            if scope.shareable {
                Text("SHARED").font(.system(size: 8, weight: .heavy)).tracking(0.3)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 5)
    }

    private func row(_ entry: MCPConfigService.Entry) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(entry.disabled ? Color.secondary.opacity(0.35) : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.disabled ? .secondary : .primary)
                    if entry.disabled { tag("OFF") }
                }
                Text(entry.transport).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            rowActions(entry)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 8.5, weight: .heavy)).tracking(0.3)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }

    private func rowActions(_ entry: MCPConfigService.Entry) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !entry.disabled },
                set: { newVal in run { try MCPConfigService.setDisabled(entry, !newVal) } }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(.accentColor)
            .help(entry.disabled ? "Enable" : "Disable")

            Menu {
                moveMenu(entry)
                Divider()
                Button(role: .destructive) { run { try MCPConfigService.delete(entry) } } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func moveMenu(_ entry: MCPConfigService.Entry) -> some View {
        if case .user = entry.scope {} else {
            Button { run { try MCPConfigService.move(entry, to: .user) } } label: {
                Label("Move to Global", systemImage: "globe")
            }
        }
        Button { moveToPickedProject(entry, shared: false) } label: {
            Label("Move to Project-local…", systemImage: "folder")
        }
        Button { moveToPickedProject(entry, shared: true) } label: {
            Label("Move to Project .mcp.json…", systemImage: "folder.badge.person.crop")
        }
    }

    // MARK: - Actions

    private var groupedScopes: [(MCPConfigService.Scope, [MCPConfigService.Entry])] {
        var order: [String] = []
        var map: [String: (MCPConfigService.Scope, [MCPConfigService.Entry])] = [:]
        for e in entries {
            if map[e.scope.key] == nil { order.append(e.scope.key); map[e.scope.key] = (e.scope, []) }
            map[e.scope.key]!.1.append(e)
        }
        // Global first, then the rest as they appeared (already sorted by service).
        return order.sorted { a, b in (a == "user" ? 0 : 1, a) < (b == "user" ? 0 : 1, b) }
            .compactMap { map[$0] }
    }

    private func reload() { entries = MCPConfigService.list() }

    private func run(_ op: () throws -> Void) {
        do { try op(); errorText = nil; reload() }
        catch { errorText = "\(error)" }
    }

    private func moveToPickedProject(_ entry: MCPConfigService.Entry, shared: Bool) {
        guard let path = Self.pickProjectDir() else { return }
        run { try MCPConfigService.move(entry, to: shared ? .project(projectPath: path) : .local(projectPath: path)) }
    }

    static func pickProjectDir() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose project"
        panel.message = "Pick the project folder for this MCP server"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - Add editor

private struct MCPAddEditor: View {
    var onClose: (_ didSave: Bool) -> Void

    @State private var name = ""
    @State private var kind = 0   // 0 = stdio, 1 = http
    @State private var json = MCPConfigService.stdioTemplate
    @State private var scopeChoice = 0   // 0 = user, 1 = local, 2 = project
    @State private var pickedPath: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name, placeholder: "e.g. my-mcp")

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Transport").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: $kind) {
                            Text("stdio (command)").tag(0)
                            Text("HTTP (url)").tag(1)
                        }.pickerStyle(.segmented).labelsHidden()
                        .onChange(of: kind) { _, new in
                            json = new == 0 ? MCPConfigService.stdioTemplate : MCPConfigService.httpTemplate
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Definition (JSON)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: $json)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 150)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Scope").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: $scopeChoice) {
                            Text("Global").tag(0)
                            Text("Project-local").tag(1)
                            Text("Project .mcp.json").tag(2)
                        }.pickerStyle(.segmented).labelsHidden()
                        if scopeChoice != 0 {
                            HStack(spacing: 6) {
                                Button("Choose project…") { pickedPath = MCPManagerSheet.pickProjectDir() }
                                    .controlSize(.small)
                                if let pickedPath {
                                    Text(URL(fileURLWithPath: pickedPath).lastPathComponent)
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Cancel") { onClose(false) }
                Spacer()
                Button("Add") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            error = "Definition is not valid JSON."; return
        }
        let scope: MCPConfigService.Scope
        switch scopeChoice {
        case 1, 2:
            guard let p = pickedPath else { error = "Choose a project folder first."; return }
            scope = scopeChoice == 1 ? .local(projectPath: p) : .project(projectPath: p)
        default:
            scope = .user
        }
        do {
            try MCPConfigService.add(name: name, scope: scope, defJSON: data)
            onClose(true)
        } catch {
            self.error = "\(error)"
        }
    }
}
