import SwiftUI

/// Bridge that lets a SwiftUI accessory bar send raw bytes into whichever terminal
/// transport a screen uses (ttyd for edge agents, the LAN peer link for Mac
/// sessions). The representable sets `send` once its client is connected; the bar
/// calls it. Kept transport-agnostic so both terminal screens reuse one bar.
@MainActor
@Observable
final class TerminalKeySender {
    /// Wired by the terminal view once its client is live. No-op until then.
    var send: ([UInt8]) -> Void = { _ in }
    /// Dims the bar while the session is deliberately locked. It no longer swallows
    /// the tap: `send` routes to the lock gate, which prompts to unlock. Dropping the
    /// key here would resurrect the silent no-op this whole change exists to kill.
    var enabled: Bool = true

    func emit(_ bytes: [UInt8]) {
        send(bytes)
    }
}

/// The keys a hardware keyboard can't reach on iOS but a terminal constantly needs:
/// Esc, Tab, Ctrl-C (interrupt), and the arrow keys (history + TUI navigation).
/// Sits above the software keyboard as an accessory strip.
struct TerminalAccessoryBar: View {
    let sender: TerminalKeySender

    private static let esc: [UInt8] = [0x1b]
    private static let tab: [UInt8] = [0x09]
    private static let ctrlC: [UInt8] = [0x03]
    private static let up: [UInt8] = [0x1b, 0x5b, 0x41]
    private static let down: [UInt8] = [0x1b, 0x5b, 0x42]
    private static let right: [UInt8] = [0x1b, 0x5b, 0x43]
    private static let left: [UInt8] = [0x1b, 0x5b, 0x44]

    var body: some View {
        HStack(spacing: 8) {
            key("esc") { sender.emit(Self.esc) }
            key("tab") { sender.emit(Self.tab) }
            key("^C") { sender.emit(Self.ctrlC) }
            Spacer(minLength: 4)
            arrow("chevron.left") { sender.emit(Self.left) }
            arrow("chevron.up") { sender.emit(Self.up) }
            arrow("chevron.down") { sender.emit(Self.down) }
            arrow("chevron.right") { sender.emit(Self.right) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .opacity(sender.enabled ? 1 : 0.4)
        .allowsHitTesting(sender.enabled)
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Text(label)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName(label))
    }

    private func arrow(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: system)
                .font(.footnote.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func accessibilityName(_ label: String) -> String {
        switch label {
        case "esc": return "Escape"
        case "tab": return "Tab"
        case "^C":  return "Control C, interrupt"
        default:    return label
        }
    }
}
