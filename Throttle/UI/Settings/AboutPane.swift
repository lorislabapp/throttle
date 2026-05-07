import SwiftUI

struct AboutPane: View {
    @State private var lastCheckLabel: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Throttle")
                .font(.title)
            Text("Version \(version)")
                .foregroundStyle(.secondary)

            Button {
                UpdaterService.shared.checkForUpdates()
                refreshLastCheck()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.clockwise.circle")
            }
            .controlSize(.regular)
            .padding(.top, 4)

            if !lastCheckLabel.isEmpty {
                Text(lastCheckLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider().padding(.horizontal, 80)
            Text("Built by LorisLabs.")
                .foregroundStyle(.secondary)
            Link("lorislab.fr/throttle", destination: URL(string: "https://lorislab.fr/throttle")!)
            Link("EULA", destination: URL(string: "https://lorislab.fr/throttle/eula")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { refreshLastCheck() }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func refreshLastCheck() {
        if let date = UpdaterService.shared.lastCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            formatter.unitsStyle = .full
            lastCheckLabel = String(localized: "Last checked: ") + formatter.localizedString(for: date, relativeTo: Date())
        } else {
            lastCheckLabel = ""
        }
    }
}
