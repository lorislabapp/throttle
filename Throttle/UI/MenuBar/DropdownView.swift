import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Throttle")
                .font(.headline)
            Text("Dropdown stub — Task 10 fills this in.")
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit Throttle") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
    }
}
