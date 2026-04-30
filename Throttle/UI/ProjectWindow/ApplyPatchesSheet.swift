import AppKit
import SwiftUI

/// Walks the user through every `AssistantPatch` the AI proposed, one
/// at a time. For each patch:
///   - Show the file name + reason
///   - Render a side-by-side diff preview (current SEARCH text vs the
///     REPLACE text) so the user sees exactly what's about to change
///   - Apply / Skip / Stop the queue
///
/// Apply runs the same `FileEditor` actor as the manual Optimizer tab —
/// so backups, atomic write, and verification all still happen. The
/// AI cannot bypass the safety net.
struct ApplyPatchesSheet: View {
    let patches: [AssistantPatch]
    let onClose: () -> Void
    /// Called once when the sheet closes, with the count of patches the
    /// user actually accepted. The Assistant tab uses this to drop a
    /// follow-up assistant message confirming the apply + suggesting a
    /// next step, so the user doesn't have to read backwards through
    /// the chat to verify what was done.
    var onCompleted: ((Int, Int) -> Void)? = nil

    @State private var index: Int = 0
    @State private var status: String = ""
    @State private var done: Set<UUID> = []
    @State private var skipped: Set<UUID> = []

    private var current: AssistantPatch? {
        guard index >= 0, index < patches.count else { return nil }
        return patches[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let p = current {
                ScrollView {
                    patchView(p)
                        .padding(20)
                }
            } else {
                summary
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 540)
    }

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.rays")
                .foregroundStyle(.tint)
            Text("Review changes (\(index + 1)/\(patches.count))")
                .font(.headline)
            Spacer()
            Button("Close") {
                onCompleted?(done.count, skipped.count)
                onClose()
            }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func patchView(_ p: AssistantPatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.kind == .create ? "CREATE" : "REPLACE")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(p.kind == .create ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(p.kind == .create ? Color.blue : Color.orange)
                    Text(p.filePath)
                        .font(.callout.monospaced().weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !p.reason.isEmpty {
                    Text(p.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if p.kind == .replace {
                HStack(alignment: .top, spacing: 12) {
                    diffPane(title: String(localized: "Current"),
                             body: p.search,
                             tint: .red)
                    diffPane(title: String(localized: "Proposed"),
                             body: p.replace,
                             tint: .green)
                }
            } else {
                diffPane(title: String(localized: "New file content"),
                         body: p.replace,
                         tint: .blue)
                    .frame(maxWidth: .infinity)
            }
            // Validation banner per patch type.
            switch p.kind {
            case .replace:
                if !FileManager.default.fileExists(atPath: p.filePath) {
                    Label("File doesn't exist on disk — patch will be skipped.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            case .create:
                if FileManager.default.fileExists(atPath: p.filePath) {
                    Label("File already exists — Apply will overwrite it (the original is backed up).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diffPane(title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(tint)
            ScrollView {
                Text(body)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
            .background(tint.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: some View {
        VStack(spacing: 12) {
            Image(systemName: done.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(done.isEmpty ? Color.secondary : Color.green)
            Text("\(done.count) applied · \(skipped.count) skipped")
                .font(.headline)
            if !done.isEmpty {
                Text("Backups are kept beside each file (`.bak.<timestamp>`) and centrally in ~/Library/Application Support/com.lorislab.throttle/backups/. Use the Optimizer tab's Rollback button if anything looks wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if current != nil {
                Button("Skip") { skipCurrent() }
                    .keyboardShortcut("s")
                Button {
                    Task { await applyCurrent() }
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            } else {
                Button("Done") {
                    onCompleted?(done.count, skipped.count)
                    onClose()
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Actions

    private func skipCurrent() {
        guard let p = current else { return }
        skipped.insert(p.id)
        advance()
    }

    private func applyCurrent() async {
        guard let p = current else { return }
        let url = URL(fileURLWithPath: p.filePath)
        do {
            switch p.kind {
            case .replace:
                guard FileManager.default.fileExists(atPath: url.path) else {
                    status = String(localized: "File doesn't exist — skipped.")
                    skipped.insert(p.id)
                    advance()
                    return
                }
                let original = try String(contentsOf: url, encoding: .utf8)
                guard original.contains(p.search) else {
                    status = String(localized: "SEARCH text not found (the file may have changed since the assistant looked). Skipping to keep it safe.")
                    skipped.insert(p.id)
                    advance()
                    return
                }
                let updated = original.replacingOccurrences(of: p.search, with: p.replace)
                _ = try await FileEditor.shared.write(url, contents: updated)
            case .create:
                // Make sure the parent dir exists, then write fresh.
                // FileEditor only handles existing files; for CREATE we
                // do the write ourselves since there's nothing to back
                // up. If the file does exist, we delegate to FileEditor
                // to back up + overwrite.
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try await FileEditor.shared.write(url, contents: p.replace)
                } else {
                    try p.replace.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            done.insert(p.id)
            status = String(localized: "Applied.")
            advance()
        } catch {
            status = String(localized: "Apply failed: \(error.localizedDescription)")
        }
    }

    private func advance() {
        if index + 1 < patches.count {
            index += 1
            status = ""
        } else {
            index = patches.count  // out of range → triggers summary view
        }
    }
}
