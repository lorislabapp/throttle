import SwiftUI

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Throttle")
                .font(.title)
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Divider().padding(.horizontal, 80)
            Text("Built by LorisLabs.")
                .foregroundStyle(.secondary)
            Link("lorislab.fr/throttle", destination: URL(string: "https://lorislab.fr/throttle")!)
            Link("EULA", destination: URL(string: "https://lorislab.fr/throttle/eula")!)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
