import SwiftUI

struct GeneralPane: View {
    @State private var loginItemsEnabled: Bool = LoginItemService.isEnabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Throttle at login", isOn: $loginItemsEnabled)
                    .onChange(of: loginItemsEnabled) { _, newValue in
                        try? LoginItemService.setEnabled(newValue)
                    }
            }
            Section("Updates") {
                Text("Sparkle update channel — wired in Plan 3.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
