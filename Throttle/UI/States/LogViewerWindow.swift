import SwiftUI

struct LogViewerWindow: View {
    @State private var contents: String = "Loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Throttle Logs").font(.headline)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                }
            }
            .padding()
            ScrollView {
                Text(contents)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 640, height: 480)
        .task {
            await load()
        }
    }

    private func load() async {
        let url = AppLogger.logFileURL
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) {
            contents = s
        } else {
            contents = "(no logs yet)"
        }
    }
}
