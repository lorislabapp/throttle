import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct DevUnlockSheet: View {
    @Environment(\.dismiss) var dismiss
    @State var key: String = ""
    @State var status: String = ""
    @State var isError: Bool = false
    @FocusState var keyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(.tint)
                Text("Developer unlock")
                    .font(.headline)
            }
            Text("Paste the dev key to unlock Pro permanently on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Unlock key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($keyFocused)
                .onSubmit { tryUnlock() }
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") { tryUnlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { keyFocused = true }
    }

    func tryUnlock() {
        let ok = DevUnlockService.shared.attemptUnlock(key: key)
        if ok {
            status = String(localized: "Pro unlocked on this Mac. Closing…")
            isError = false
            // Give the success message a beat to land, then dismiss
            // and refresh AppState so the menu-bar UI re-renders with
            // the new Pro state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismiss()
                NotificationCenter.default.post(name: .devUnlockChanged, object: nil)
            }
        } else {
            status = String(localized: "Wrong key.")
            isError = true
            key = ""
        }
    }
}
