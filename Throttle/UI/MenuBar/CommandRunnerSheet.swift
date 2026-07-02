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
    @State private var pendingDelete: CommandRunnerService.SavedCommand?
    @State private var copied = false

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
                    Text("Run saved shell commands straight from Throttle — no claude session, no ! prefix, zero tokens. Runs through your login shell (PATH + secrets).")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                    if model.commands.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                            Text("No saved commands yet — click New to add one.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 44)
                    }
                    ForEach(model.commands) { c in
                        row(c)
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    }
                }
            }
            if let result { outputPanel(result) }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = pendingDelete { model.remove(c.id) }; pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("This can't be undone.") }
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
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
            } else {
                RunButton { run(c) }.disabled(running != nil)
            }
            Menu {
                Button { editing = .existing(c) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { pendingDelete = c } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 14))
                    .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(running != nil)
            .help("Edit or delete")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func outputPanel(_ r: CommandRunnerService.RunResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(r.ok ? Color.green : Color.red).frame(width: 8, height: 8)
                HStack(spacing: 0) {
                    Text(resultName).foregroundStyle(.secondary)
                    Text(" — exit \(r.exitCode) · \(r.durationMs) ms\(r.truncated ? " · truncated" : "")")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.output, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Color.green : .secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Copy output")
                Button { result = nil } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Dismiss")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                Text(r.output.isEmpty ? "(no output)" : r.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(r.output.isEmpty ? .tertiary : .primary)
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

// MARK: - Run button (primary action — accent, hover fill, 28×28 hit target)

private struct RunButton: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hover ? Color.accentColor.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Run")
        .onHover { hover = $0 }
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
