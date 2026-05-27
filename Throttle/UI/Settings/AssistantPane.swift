import SwiftUI

/// Settings pane for the AI Assistant (Project window → Assistant tab).
/// Controls Caveman mode, quality preference, provider selection, and ccusage import.
struct AssistantPane: View {
    @Environment(AppState.self) private var appState

    @AppStorage("cavemanModeEnabled") private var cavemanModeEnabled = false
    @AppStorage("aiQualityPreference") private var qualityPreference: String = "maxAccuracy"

    @State private var isImporting = false
    @State private var importStatus: String?
    @State private var showImportAlert = false

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
                Button {
                    Task {
                        await importFromCcusage()
                    }
                } label: {
                    HStack {
                        if isImporting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isImporting ? "Importing..." : "Import from ccusage")
                    }
                }
                .disabled(isImporting)

                if let status = importStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.starts(with: "✓") ? .green : .secondary)
                }

                Text("Migrate your existing ccusage data into Throttle. Requires ccusage CLI (npx ccusage@latest).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Data Import", systemImage: "arrow.down.circle")
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
        .alert("Import Result", isPresented: $showImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importStatus ?? "")
        }
    }

    private func importFromCcusage() async {
        isImporting = true
        importStatus = nil

        do {
            let importer = CcusageImporter(database: appState.database)
            let daysImported = try await importer.importFromCcusage()
            importStatus = "✓ Imported \(daysImported) days of usage data"
            showImportAlert = true
            // Refresh AppState to show new data
            await MainActor.run {
                appState.refresh()
            }
        } catch {
            importStatus = "❌ \(error.localizedDescription)"
            showImportAlert = true
        }

        isImporting = false
    }
}

#Preview {
    AssistantPane()
        .frame(width: 520, height: 380)
}
