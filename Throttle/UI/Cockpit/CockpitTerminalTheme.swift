import AppKit
import SwiftTerm

/// The Cockpit's embedded-terminal look. ONE fixed palette that matches the
/// precise-cockpit design language — deliberately NOT a user-facing theme
/// picker (that's Warp's turf and an explicit non-goal). The single lever we
/// care about: claude already colour-codes its own output (prose in the default
/// foreground, tool-call / meta lines dimmed). We can't re-parse the PTY to
/// re-style it, but we DO own the 256-colour table — so we tune ANSI 8 (the
/// "dim" colour claude uses for tool meta) to a clearly muted grey and ANSI 15
/// (bright white, prose emphasis) to pop. That makes Claude's answers stand out
/// from the actions it runs, using only the palette, no stream rewriting.
enum CockpitTerminalTheme {

    /// hex 0xRRGGBB → SwiftTerm.Color (16-bit channels, byte * 257).
    private static func c(_ hex: UInt32) -> SwiftTerm.Color {
        let r = UInt16((hex >> 16) & 0xFF) * 257
        let g = UInt16((hex >> 8) & 0xFF) * 257
        let b = UInt16(hex & 0xFF) * 257
        return SwiftTerm.Color(red: r, green: g, blue: b)
    }

    private static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static let background: UInt32 = 0x121214   // graphite, not pure black
    private static let foreground: UInt32 = 0xF2F2F4   // bright soft-white (claude prose)
    private static let accent:     UInt32 = 0x0071E3   // system blue — caret only

    /// 16 ANSI colours. Indices 8 (dim grey) and 15 (bright white) are the
    /// load-bearing ones for prose-vs-action contrast.
    private static let ansi: [UInt32] = [
        0x1A1A1D, // 0  black
        0xFF6B68, // 1  red
        0x5DD08A, // 2  green
        0xE6C079, // 3  yellow
        0x6AA0FF, // 4  blue
        0xC99BFF, // 5  magenta
        0x65C7D8, // 6  cyan
        0xC8C8CC, // 7  white (normal)
        0x595962, // 8  bright-black  → DIM: claude's tool-call / meta grey (recessive)
        0xFF8A87, // 9  bright red
        0x7EE0A3, // 10 bright green
        0xF2D08C, // 11 bright yellow
        0x8AB6FF, // 12 bright blue
        0xD9B8FF, // 13 bright magenta
        0x8AD8E6, // 14 bright cyan
        0xF4F4F6, // 15 bright white → prose emphasis pops
    ]

    /// The graphite terminal background, for container views behind the PTY.
    static var backgroundColor: NSColor { ns(background) }

    static func apply(to term: LocalProcessTerminalView) {
        term.installColors(ansi.map(c))
        term.nativeBackgroundColor = ns(background)
        term.nativeForegroundColor = ns(foreground)
        term.caretColor = ns(accent)
        term.selectedTextBackgroundColor = ns(accent, alpha: 0.30)
        term.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        term.layer?.backgroundColor = ns(background).cgColor
        // The nativeBackgroundColor setter doesn't force a repaint on its own.
        term.needsDisplay = true
    }
}
