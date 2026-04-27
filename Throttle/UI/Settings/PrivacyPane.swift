import SwiftUI

struct PrivacyPane: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Local logs") {
                Button("Show Logs…") {
                    openWindow(id: "logs")
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
