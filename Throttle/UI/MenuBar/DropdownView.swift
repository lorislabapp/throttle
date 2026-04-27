import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Throttle")
                .font(.headline)

            if !appState.firstRunDone {
                Button {
                    openWindow(id: "first-run")
                } label: {
                    Label("Finish setup", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Dropdown stub — Task 10 fills this in.")
                .foregroundStyle(.secondary)

            Divider()

            Button("Settings…") {
                openSettings()
            }

            Button("Quit Throttle") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
