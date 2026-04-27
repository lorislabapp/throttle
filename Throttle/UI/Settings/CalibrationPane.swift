import GRDB
import SwiftUI

struct CalibrationPane: View {
    @Environment(AppState.self) private var appState
    @State private var session5hCap: String = ""
    @State private var weeklyAllCap: String = ""
    @State private var weeklySonnetCap: String = ""

    var body: some View {
        Form {
            Section("Caps") {
                row(label: "Session (5h)", text: $session5hCap, kind: .session5h)
                row(label: "Weekly all models", text: $weeklyAllCap, kind: .weeklyAll)
                row(label: "Weekly Sonnet only", text: $weeklySonnetCap, kind: .weeklySonnet)
            }
            Section {
                Button("Reset all calibrations") {
                    resetAll()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadCurrent() }
    }

    private func row(label: String, text: Binding<String>, kind: WindowKind) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("tokens", text: text)
                .frame(width: 140)
                .multilineTextAlignment(.trailing)
            Button("Save") {
                if let v = Int(text.wrappedValue) {
                    saveManual(kind: kind, capTokens: v)
                }
            }
        }
    }

    private func loadCurrent() async {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        let values: (Int, Int, Int)? = try? await Task.detached {
            try pool.read { db in
                let s = try DatabaseQueries.calibration(in: db, kind: .session5h)?.capTokens ?? 0
                let a = try DatabaseQueries.calibration(in: db, kind: .weeklyAll)?.capTokens ?? 0
                let n = try DatabaseQueries.calibration(in: db, kind: .weeklySonnet)?.capTokens ?? 0
                return (s, a, n)
            }
        }.value
        guard let values else { return }
        session5hCap = "\(values.0)"
        weeklyAllCap = "\(values.1)"
        weeklySonnetCap = "\(values.2)"
    }

    private func saveManual(kind: WindowKind, capTokens: Int) {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            try CalibrationEngine.setManual(in: db, kind: kind, capTokens: capTokens)
        }
        appState.refresh()
    }

    private func resetAll() {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return }
        try? pool.write { db in
            for kind in WindowKind.allCases {
                try CalibrationEngine.reset(in: db, kind: kind)
            }
        }
        Task { await loadCurrent() }
        appState.refresh()
    }
}
