import AppKit
import SwiftTerm

/// The Cockpit's embedded-terminal look. A small set of CURATED presets — not a
/// full colour/sound editor (that's Warp's turf and an explicit non-goal). Each
/// preset is a finished, coherent look. The load-bearing pair in every palette
/// is ANSI 8 (the "dim" colour claude uses for tool/meta lines, kept recessive)
/// and ANSI 15 (bright white, prose emphasis) so Claude's answers stand out from
/// the actions it runs — using only the palette, never rewriting the stream.
enum CockpitTerminalTheme {

    enum Preset: String, CaseIterable, Identifiable {
        case graphite, midnight, light, contrast
        var id: String { rawValue }
        var label: String {
            switch self {
            case .graphite: return "Graphite"
            case .midnight: return "Midnight"
            case .light:    return "Light"
            case .contrast: return "High Contrast"
            }
        }
    }

    private static let defaultsKey = "cockpitTerminalPreset"

    static var current: Preset {
        get { Preset(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .graphite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    // MARK: - Palettes

    private struct Palette {
        let bg: UInt32, fg: UInt32, accent: UInt32
        let ansi: [UInt32]   // 16 ANSI colours
    }

    private static func palette(_ p: Preset) -> Palette {
        switch p {
        case .graphite:
            return Palette(bg: 0x121214, fg: 0xF2F2F4, accent: 0x0071E3, ansi: [
                0x1A1A1D, 0xFF6B68, 0x5DD08A, 0xE6C079, 0x6AA0FF, 0xC99BFF, 0x65C7D8, 0xC8C8CC,
                0x595962, 0xFF8A87, 0x7EE0A3, 0xF2D08C, 0x8AB6FF, 0xD9B8FF, 0x8AD8E6, 0xF4F4F6])
        case .midnight:
            return Palette(bg: 0x0B0F1A, fg: 0xDCE3F0, accent: 0x4D9CFF, ansi: [
                0x141A2A, 0xFF6E6E, 0x59D9A0, 0xE7C97A, 0x5B9BFF, 0xB99BFF, 0x5CC8E0, 0xB6BFD2,
                0x4A5570, 0xFF9090, 0x84E8BC, 0xF2D89A, 0x86B6FF, 0xD2B8FF, 0x8EDCEE, 0xEEF3FB])
        case .light:
            // claude assumes a DARK terminal and fills diff lines with an ANSI
            // green/red BACKGROUND. On a light theme that made text invisible
            // (dark text on a dark-green/red fill; and idx0 "black" was light, so
            // black text vanished too). Fix: idx0 dark again, and the diff colours
            // (red/green + their brights) PALE so dark text stays readable on them.
            // Trade-off: green/red as foreground text is lower-contrast on white,
            // which claude rarely uses — diff readability is the case that broke.
            // red/green must be readable as FOREGROUND text on white (claude uses
            // them for +N/-N summaries and ✓/✗) — pale tones failed WCAG (~1.4:1).
            // claude colours its diff BACKGROUNDS in truecolor (not these 16), so
            // these only need to be good foregrounds; the proper diff fix is
            // `/theme light` in claude. (H01)
            return Palette(bg: 0xFBFBFD, fg: 0x1D1D1F, accent: 0x0071E3, ansi: [
                0x2B2B2E, 0xB42318, 0x067647, 0x9A6B00, 0x0060D0, 0x7A3FBF, 0x0E7C8C, 0x3A3A40,
                0x8A8A90, 0xCB3A2B, 0x0A7D4E, 0xB07E10, 0x1672E6, 0x8E54D0, 0x1894A6, 0x111114])
        case .contrast:
            return Palette(bg: 0x000000, fg: 0xFFFFFF, accent: 0x00B0FF, ansi: [
                0x000000, 0xFF5C57, 0x5AF78E, 0xF3F99D, 0x57C7FF, 0xFF6AC1, 0x9AEDFE, 0xE0E0E0,
                0x9A9AA2, 0xFF6E67, 0x6BFF9E, 0xF7FCB0, 0x6FD0FF, 0xFF82CF, 0xB0F4FF, 0xFFFFFF])
        }
    }

    // MARK: - Colour helpers

    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                        green: UInt16((hex >> 8) & 0xFF) * 257,
                        blue: UInt16(hex & 0xFF) * 257)
    }

    private static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// The current preset's terminal background, for container views behind the PTY.
    static var backgroundColor: NSColor { ns(palette(current).bg) }

    static func apply(to term: LocalProcessTerminalView) {
        let p = palette(current)
        term.installColors(p.ansi.map(c))
        term.nativeBackgroundColor = ns(p.bg)
        term.nativeForegroundColor = ns(p.fg)
        term.caretColor = ns(p.accent)
        term.selectedTextBackgroundColor = ns(p.accent, alpha: 0.30)
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        term.layer?.backgroundColor = ns(p.bg).cgColor
        term.needsDisplay = true   // the nativeBackgroundColor setter doesn't repaint on its own
    }
}
