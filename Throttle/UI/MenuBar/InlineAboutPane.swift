import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineAboutPane: View {
    @State var exportStatus: String = ""
    @State var csvStatus: String = ""
    @State var versionTapCount: Int = 0
    @State var lastTapAt: Date = .distantPast
    @State var showDevUnlockSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "Privacy")
            SettingsRow(title: "Reveal log file",
                        sub: "~/Library/Logs/Throttle — app behaviour only, no session content.") {
                SettingsButton(title: "Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.logFileURL])
                }
            }
            SettingsHair()
            SettingsRow(title: "Export diagnostics",
                        sub: exportStatus.isEmpty ? "Anonymized stats .zip to Desktop — token totals only." : exportStatus) {
                SettingsButton(title: "Export") {
                    exportStatus = String(localized: "Building…")
                    Task { @MainActor in
                        if let url = await runDiagnosticsExport() {
                            exportStatus = "Saved: \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else { exportStatus = String(localized: "Failed — see log.") }
                    }
                }
            }
            SettingsHair()
            SettingsRow(title: "Export usage CSV",
                        sub: csvStatus.isEmpty ? "Full event history to Desktop — no message content." : csvStatus) {
                SettingsButton(title: "Export") {
                    csvStatus = String(localized: "Building…")
                    Task { @MainActor in
                        if let url = await runCSVExport() {
                            csvStatus = "Saved: \(url.lastPathComponent)"
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else { csvStatus = String(localized: "Failed — see log.") }
                    }
                }
            }
            SettingsNote(text: "Throttle collects no telemetry. Future opt-ins will appear here.")
            SettingsHair()
            linkRow("Privacy policy", url: "https://lorislab.fr/throttle/privacy")

            SettingsHair()
            aboutBlock
            SettingsHair()
            linkRow("Support", url: "mailto:support@lorislab.fr")
            SettingsHair()
            linkRow("Open-source meter on GitHub", url: "https://github.com/lorislabapp/throttle-meter")
            SettingsHair()
            linkRow("EULA", url: "https://lorislab.fr/throttle/eula")
        }
        .sheet(isPresented: $showDevUnlockSheet) { DevUnlockSheet() }
    }

    var aboutBlock: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 24)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Throttle").font(.system(size: 14, weight: .semibold))
                Text("Version \(version)")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { handleVersionTap() }
            }
            Spacer(minLength: 0)
            SettingsButton(title: "Check for updates") { UpdaterService.shared.checkForUpdates() }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    func linkRow(_ title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.openInBackground(u) }
        } label: {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) > 3 { versionTapCount = 0 }
        lastTapAt = now
        versionTapCount += 1
        if versionTapCount >= 10 { versionTapCount = 0; showDevUnlockSheet = true }
    }

    @MainActor
    func runDiagnosticsExport() async -> URL? {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return nil }
        return DiagnosticsExporter.exportToDesktop(database: pool)
    }

    @MainActor
    func runCSVExport() async -> URL? {
        guard let url = try? DatabaseManager.databaseURL(),
              let pool = try? DatabasePool(path: url.path) else { return nil }
        return CSVExporter.exportToDesktop(database: pool)
    }
}

/// Minimal sheet for entering the developer-unlock key. Shown only after
/// 10 consecutive taps (within 3 s of each other) on the version label
/// in About. Submits the key to `DevUnlockService.attemptUnlock(key:)`,
/// which compares against a salted SHA-256 stored as a constant in the
/// binary. On success, Pro is unlocked permanently on this Mac and the
/// sheet dismisses.
