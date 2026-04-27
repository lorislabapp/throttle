import SwiftUI

struct FirstRunWindow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to Throttle")
                .font(.title)
            Text("First-run stub — Task 11 builds the real flow.")
            Button("Get Started") {
                appState.markFirstRunDone()
                dismiss()
            }
        }
        .padding(40)
        .frame(width: 480, height: 320)
    }
}
