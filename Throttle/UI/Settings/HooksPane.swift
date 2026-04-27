import SwiftUI

struct HooksPane: View {
    @State private var status = HookStatusService.currentStatus()

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("SessionStart router") {
                    Text(status.sessionStartRouterInstalled ? "Active" : "Not installed")
                        .foregroundStyle(status.sessionStartRouterInstalled ? .green : .secondary)
                }
                LabeledContent("PreCompact extractor") {
                    Text(status.preCompactExtractorInstalled ? "Active" : "Not installed")
                        .foregroundStyle(status.preCompactExtractorInstalled ? .green : .secondary)
                }
                if status.killSwitchSet {
                    LabeledContent("Kill switch") {
                        Text("CLAUDE_DISABLE_TOKOPT_HOOKS=1 set — hooks are disabled in your shell")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Text("Hooks management UI ships in v1.1. To install, use the Optimizer wizard (Pro). To disable, run:")
                Text("export CLAUDE_DISABLE_TOKOPT_HOOKS=1")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            // Refresh status occasionally; the hooks rarely change but reflect kill-switch toggles.
            while !Task.isCancelled {
                status = HookStatusService.currentStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
