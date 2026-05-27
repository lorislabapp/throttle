import SwiftUI

/// Settings pane for the AI Assistant (Project window → Assistant tab).
/// Controls Caveman mode, quality preference, and provider selection.
struct AssistantPane: View {
    @AppStorage("cavemanModeEnabled") private var cavemanModeEnabled = false
    @AppStorage("aiQualityPreference") private var qualityPreference: String = "maxAccuracy"

    var body: some View {
        Form {
            Section {
                Toggle("Enable Caveman Mode", isOn: $cavemanModeEnabled)
                Text("Forces ultra-terse, telegraphic responses (no full sentences). Reduces output tokens by 65-75%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Response Style", systemImage: "text.bubble")
            }

            Section {
                Picker("Quality Preference", selection: $qualityPreference) {
                    Text("Max Accuracy (Opus)").tag("maxAccuracy")
                    Text("Balanced (Sonnet)").tag("balanced")
                    Text("Speed (Haiku)").tag("speed")
                }
                .pickerStyle(.radioGroup)

                Text("Applies to API key provider only. Embedded session and Apple Intelligence use their own routing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Model Selection", systemImage: "cpu")
            }

            Section {
                Text("The Assistant audits your Claude Code config and generates patches you can apply with one click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    AssistantPane()
        .frame(width: 520, height: 380)
}
