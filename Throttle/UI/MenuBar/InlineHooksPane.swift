import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineHooksPane: View {
    @State var status = HookStatusService.currentStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Hooks", desc: "Shell integration status")
            hookRow("session-start router",
                    "Routes new sessions through Throttle.",
                    ok: status.sessionStartRouterInstalled)
            SettingsHair()
            hookRow("pre-compact",
                    "Snapshots usage before context compaction.",
                    ok: status.preCompactExtractorInstalled)
            SettingsHair()
            if status.killSwitchSet {
                hookRow("kill-switch",
                        "Active — CLAUDE_DISABLE_TOKOPT_HOOKS=1 is set; hooks are bypassed.",
                        ok: false, tag: "active", tagColor: .orange)
            } else {
                hookRow("kill-switch",
                        "Halts runs at your hard cap when set.",
                        ok: false, tag: "off")
            }
            SettingsNote(text: "Hooks are managed by the Claude Code CLI — Throttle reads their status, never edits your shell. To disable, run: export CLAUDE_DISABLE_TOKOPT_HOOKS=1")
        }
        .task {
            while !Task.isCancelled {
                status = HookStatusService.currentStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func hookRow(_ name: String, _ desc: String, ok: Bool,
                 tag: String? = nil, tagColor: Color = .secondary) -> some View {
        HStack(spacing: 11) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 14)).foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13))
                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(tag ?? (ok ? "detected" : "not installed"))
                .font(.system(size: 10, weight: .semibold).monospaced())
                .foregroundStyle(ok ? Color.green : tagColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 9).frame(minHeight: 44)
    }
}
