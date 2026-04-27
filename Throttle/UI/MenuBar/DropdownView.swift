import AppKit
import SwiftUI

struct DropdownView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            firstRunBanner
            if !appState.claudeCodeDetected {
                emptyState(message: "Claude Code not detected. Install it to start measuring.")
            } else if !appState.snapshot.hasAnyData {
                emptyState(message: "No sessions yet — start one in Claude Code.")
            } else {
                windowsList
            }
            Divider().padding(.vertical, 4)
            proSection
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Throttle")
                .font(.headline)
            Spacer()
            if let pct = appState.snapshot.session5h.percentUsed {
                Text("\(Int(pct * 100))%")
                    .font(.headline)
                    .foregroundStyle(headerColor(for: pct))
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var firstRunBanner: some View {
        if !appState.firstRunDone {
            Button {
                openWindow(id: "first-run")
            } label: {
                Label("Finish setup", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 8)
        }
    }

    private func headerColor(for pct: Double) -> Color {
        switch pct {
        case ..<0.5:  return .secondary
        case ..<0.8:  return .primary
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private func emptyState(message: String) -> some View {
        VStack {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var windowsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            windowRow(window: appState.snapshot.session5h, title: "Session (5h)")
            windowRow(window: appState.snapshot.weeklyAll, title: "Weekly all models")
            windowRow(window: appState.snapshot.weeklySonnet, title: "Weekly Sonnet only")
        }
    }

    private func windowRow(window: UsageSnapshot.Window, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if let pct = window.percentUsed {
                    Text("\(Int(pct * 100))% used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("not calibrated")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            if let pct = window.percentUsed {
                ProgressView(value: pct)
                    .progressViewStyle(.linear)
                    .tint(progressTint(for: pct))
            }
            Text("resets in \(formatDuration(window.resetInSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressTint(for pct: Double) -> Color {
        switch pct {
        case ..<0.8:  return .accentColor
        case ..<0.95: return .orange
        default:      return .red
        }
    }

    private func formatDuration(_ seconds: Int64) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var proSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lock.fill")
                Text("Run Optimizer")
                Spacer()
                Text("Pro").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                // Plan 2 wires the paywall here. For Plan 1 we just no-op.
            }
            HStack {
                Image(systemName: "lock.fill")
                Text("Manage Hooks")
                Spacer()
                Text("Pro").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open claude.ai/usage", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)

            Button {
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Throttle", systemImage: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }
}
