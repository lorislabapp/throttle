import SwiftUI

/// Full output-style manager: pick any installed style (built-in or user),
/// create / edit / delete custom ones. Drives `OutputStyleManager`, which
/// writes `~/.claude/output-styles/*.md` and the `outputStyle` settings key
/// (backed up). Applies to every `claude` session — terminal and Cockpit.
struct OutputStyleManagerSheet: View {
    var onDone: () -> Void = {}
    @State private var styles: [OutputStyleManager.Style] = []
    @State private var editing: EditTarget?

    enum EditTarget: Identifiable {
        case new
        case existing(OutputStyleManager.Style)
        var id: String { if case let .existing(s) = self { return s.id } else { return "·new" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let target = editing {
                    OutputStyleEditor(target: target) { didSave in
                        editing = nil
                        if didSave { reload() }
                    }
                } else {
                    listView
                }
            }
        }
        .frame(width: 470, height: 540)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Text(editing == nil ? "Output style" : (isNew ? "New style" : "Edit style"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if editing == nil {
                Button { editing = .new } label: { Label("New", systemImage: "plus") }
                    .controlSize(.small)
            }
            Button("Done") { onDone() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var isNew: Bool { if case .new = editing { return true }; return false }

    private var listView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("The system prompt voice for every Claude Code session — terminal and Cockpit. Throttle backs up your settings before any change.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                ForEach(styles) { style in
                    styleRow(style)
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                }
                Label("Applies to new Claude Code sessions. In an open session, run /output-style to switch it live.", systemImage: "info.circle")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private func styleRow(_ style: OutputStyleManager.Style) -> some View {
        HStack(spacing: 11) {
            Image(systemName: style.isActive ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(style.isActive ? Color.accentColor : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(style.name).font(.system(size: 13, weight: .medium))
                    if style.isBuiltIn { tag("BUILT-IN") }
                    else if style.isTemplate { tag("READY") }
                }
                Text(style.description).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if style.fileURL != nil { rowActions(style) }   // edit/delete only for real files
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { activate(style) }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.system(size: 8.5, weight: .heavy)).tracking(0.3)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }

    private func rowActions(_ style: OutputStyleManager.Style) -> some View {
        HStack(spacing: 4) {
            Button { editing = .existing(style) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Edit")
            Button { delete(style) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func reload() { styles = OutputStyleManager.allStyles() }

    private func activate(_ style: OutputStyleManager.Style) {
        guard !style.isActive else { return }
        try? OutputStyleManager.activate(style)   // installs a curated template's file if needed
        reload()
    }

    private func delete(_ style: OutputStyleManager.Style) {
        try? OutputStyleManager.delete(style)
        reload()
    }
}

// MARK: - Editor

private struct OutputStyleEditor: View {
    let target: OutputStyleManagerSheet.EditTarget
    var onClose: (_ didSave: Bool) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var body_ = ""
    @State private var keepCoding = true
    @State private var existingURL: URL?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isNew { templatePicker }
                    field("Name", text: $name, placeholder: "e.g. Caveman")
                    field("Description", text: $description, placeholder: "One line — shown in the picker.")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Instructions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        TextEditor(text: $body_)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 180)
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        Text("Appended to the system prompt. Keep it short — it ships on every request.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Toggle(isOn: $keepCoding) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Keep engineering instructions").font(.system(size: 12, weight: .medium))
                            Text("Recommended — only shapes voice/verbosity, never blanks Claude Code's coding prompt.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.switch).tint(.accentColor)
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("Cancel") { onClose(false) }
                Spacer()
                Button("Save & activate") { save(activate: true) }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .onAppear(perform: loadIfNeeded)
    }

    private var isNew: Bool { if case .new = target { return true }; return false }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start from").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(OutputStyleManager.templates, id: \.name) { t in
                    Button(t.name) { apply(t) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func apply(_ t: OutputStyleManager.Template) {
        name = t.name; description = t.description; body_ = t.body; keepCoding = t.keepCoding
    }

    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        if case let .existing(style) = target {
            name = style.name
            description = style.description
            body_ = OutputStyleManager.body(of: style) ?? ""
            existingURL = style.fileURL
        }
    }

    private func save(activate: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let url = try? OutputStyleManager.saveStyle(
            name: trimmed, description: description, body: body_,
            keepCoding: keepCoding, fileURL: existingURL) else { onClose(false); return }
        _ = url
        if activate { try? OutputStyleManager.setActive(trimmed) }
        onClose(true)
    }
}
