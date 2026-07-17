import SwiftUI

/// Live connection state for a terminal screen, so the UI never shows a frozen
/// black terminal with no explanation (the #1 confusing failure the review found).
/// Both terminal representables push into this; the chrome renders it.
@MainActor
@Observable
final class TerminalConnection {
    enum State: Equatable {
        case connecting
        case live
        case reconnecting
        case failed(String)
        /// LAN terminal off-network — output only, no write path.
        case readOnly(String)
    }
    var state: State = .connecting
}

/// Shared chrome for both terminal screens: a Face ID lock banner (read-only until
/// unlocked), a connection-state overlay (connecting / reconnecting / failed+retry),
/// and the accessory key bar. Keeps the two terminals' UX identical and removes the
/// black-screen-no-feedback failure mode.
struct TerminalHost<Terminal: View>: View {
    let title: String
    let lockState: TerminalLockState
    let keySender: TerminalKeySender
    let connection: TerminalConnection
    var onRetry: (() -> Void)? = nil
    @ViewBuilder var terminal: () -> Terminal

    @State private var unlocking = false

    var body: some View {
        VStack(spacing: 0) {
            if case .failed = connection.state {} else if !lockState.unlocked {
                lockBanner
            }
            ZStack {
                terminal()
                    .ignoresSafeArea(.container, edges: .bottom)
                overlay
            }
            TerminalAccessoryBar(sender: keySender)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A toggle, not a one-way door: typing is on by default, and locking a
                // session is a deliberate act you can take and undo.
                Button { lockState.unlocked ? lockState.lock() : unlock() } label: {
                    Image(systemName: lockState.unlocked ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(lockState.unlocked ? MirrorUI.ok : MirrorUI.warn)
                }
                .disabled(unlocking)
                .accessibilityLabel(lockState.unlocked ? "Typing unlocked — tap to lock" : "Locked — tap to unlock typing")
            }
        }
        .onChange(of: lockState.unlocked) { _, unlocked in keySender.enabled = unlocked }
    }

    @ViewBuilder private var overlay: some View {
        switch connection.state {
        case .connecting:
            statusCard { ProgressView(); Text("Connecting…").font(.footnote).foregroundStyle(.secondary) }
        case .reconnecting:
            statusCard { ProgressView(); Text("Reconnecting…").font(.footnote).foregroundStyle(.secondary) }
        case .failed(let reason):
            statusCard {
                Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(MirrorUI.warn)
                Text(reason).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let onRetry {
                    Button("Retry") { onRetry() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        case .readOnly(let reason):
            VStack { Spacer(); banner(reason, tint: MirrorUI.accent, glyph: "eye") }
        case .live:
            EmptyView()
        }
    }

    private func statusCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(40)
    }

    private var lockBanner: some View {
        Button { unlock() } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text(lockState.lastError ?? "Locked for typing — tap to unlock with Face ID")
                    .font(.footnote.weight(.medium))
                Spacer()
                if unlocking { ProgressView() }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(MirrorUI.warn.opacity(0.15))
            .foregroundStyle(MirrorUI.warn)
        }
        .buttonStyle(.plain)
        .disabled(unlocking)
    }

    private func banner(_ text: String, tint: Color, glyph: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
            Text(text).font(.footnote.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.15))
        .foregroundStyle(tint)
    }

    private func unlock() {
        guard !lockState.unlocked, !unlocking else { return }
        unlocking = true
        Task {
            let ok = await lockState.unlock()
            unlocking = false
            Haptics.tap(ok ? .success : .error)
        }
    }
}
