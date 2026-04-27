import SwiftUI

@main
struct ThrottleApp: App {
    var body: some Scene {
        MenuBarExtra("Throttle", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            Text("Throttle is starting…")
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
