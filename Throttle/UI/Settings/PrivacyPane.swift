import AppKit
import SwiftUI

struct PrivacyPane: View {
    var body: some View {
        Form {
            Section("Local logs") {
                Button("Reveal log file in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                }
                Text("Logs include app behaviour only — no session content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Telemetry") {
                Text("Throttle does not collect telemetry. Future opt-ins will appear here.")
                    .foregroundStyle(.secondary)
            }
            Section("Privacy policy") {
                Link("lorislab.fr/throttle/privacy", destination: URL(string: "https://lorislab.fr/throttle/privacy")!)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
