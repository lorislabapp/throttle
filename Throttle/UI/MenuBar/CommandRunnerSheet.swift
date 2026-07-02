import AppKit
import SwiftUI

/// Local command runner UI: saved shell commands you run with one tap — no
/// `claude` session, no `!`, zero tokens. Drives `CommandRunnerService`.
struct CommandRunnerSheet: View {
    var onDone: () -> Void = {}
    @State private var model = CommandRunnerService.shared
    @State private var editing: EditTarget?
    @State private var running: UUID?
    @State private var result: CommandRunnerService.RunResult?
    @State private var resultName = ""

    enum EditTarget: Identifiable {
        case new
        case existing(CommandRunnerService.SavedCommand)
        var id: String { if case let .existing(c) = self { return c.id.uuidString } else { return "·new" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let target = editing {
                CommandEditor(target: target) { editing = nil }
            } else {
                listView
            }
        }
        .frame(width: 520, height: 600)
    }

    private var header: some View {
        HStack {
            Text(editing == nil ? "Command runner" : "Command")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if editing == nil {
                Button { editing = .new } label: { Label("New", systemImage: "plus") }.controlSize(.small)
            }
            Button("Done") { onDone() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Run saved shell commands straight from Throttle — no claude session, no `!`, zero tokens. Runs through your login shell (PATH + secrets).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    if model.commands.isEmpty {
                        Text("No saved commands yet. Tap New.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).padding(24)
                    }
                    ForEach(model.commands) { c in
                        row(c)
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    }
                }
            }
            if let result { outputPanel(result) }
        }
    }

    private func row(_ c: CommandRunnerService.SavedCommand) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 13, weight: .medium))
                Text(c.command).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if running == c.id {
                ProgressView().controlSize(.small)
            } else {
                Button { run(c) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless).help("Run")
            }
            Button { editing = .existing(c) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit").foregroundStyle(.secondary)
            Button { model.remove(c.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func outputPanel(_ r: CommandRunnerService.RunResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(r.ok ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text("\(resultName) — exit \(r.exitCode) · \(r.durationMs) ms\(r.truncated ? " · truncated" : "")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.output, forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy output")
                Button { result = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                Text(r.output.isEmpty ? "(no output)" : r.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .frame(height: 200)
            .background(Color.primary.opacity(0.03))
        }
    }

    private func run(_ c: CommandRunnerService.SavedCommand) {
        running = c.id; result = nil
        Task {
            let r = await model.run(c)
            running = nil; resultName = c.name; result = r
        }
    }
}

// MARK: - Editor

private struct CommandEditor: View {
    let target: CommandRunnerSheet.EditTarget
    var onClose: () -> Void
    @State private var model = CommandRunnerService.shared
    @State private var name = ""
    @State private var command = ""
    @State private var cwd = ""
    @State private var existing: CommandRunnerService.SavedCommand?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Name", text: $name, placeholder: "e.g. Restart mcp-gateway")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Command").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: $command)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 120).padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        Text("Runs via zsh -lc — your PATH, aliases and secrets apply.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    field("Working directory (optional)", text: $cwd, placeholder: "~ if empty — absolute path")
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Cancel") { onClose() }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .onAppear {
            guard !loaded else { return }; loaded = true
            if case let .existing(c) = target { name = c.name; command = c.command; cwd = c.cwd ?? ""; existing = c }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let cwdVal = cwd.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cwd.trimmingCharacters(in: .whitespaces)
        if var e = existing {
            e.name = name; e.command = command; e.cwd = cwdVal; model.update(e)
        } else {
            model.add(name: name, command: command, cwd: cwdVal)
        }
        onClose()
    }
}
