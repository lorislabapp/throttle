import AppKit
import SwiftUI
import ThrottleShared

struct BarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 980 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One segment of the view switcher — the dominant control. Active item is raised
/// onto an elevated surface with the accent; inactive is quiet, brightening on hover.
struct SwitcherItem: View {
    let icon: String
    let label: String
    let isOn: Bool
    let iconOnly: Bool
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                if !iconOnly {
                    Text(label).font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                }
            }
            .foregroundStyle(isOn ? Color.accentColor : (hover ? Color.primary : Color.secondary))
            .padding(.horizontal, iconOnly ? 9 : 11).frame(height: 26)
            .background(isOn ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                             : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(label)
    }
}

/// A stateful toolbar toggle (Audit, Shell): a bordered chip whose ON state fills
/// with a tinted accent + accent ring so it reads unmistakably as on, not momentary.
struct ToolbarToggle: View {
    let icon: String
    var label: String
    let isOn: Bool
    let iconOnly: Bool
    let help: String
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .medium))
                if !iconOnly { Text(label).font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(isOn ? Color.accentColor : (hover ? Color.primary : Color.secondary))
            .padding(.horizontal, iconOnly ? 7 : 9).frame(height: 26)
            .background(isOn ? Color.accentColor.opacity(0.14)
                             : (hover ? Color.primary.opacity(0.06) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isOn ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.10), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(help).accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

/// A quiet momentary utility glyph (26×26) for the revealed shelf. Optional `tint`
/// lets a stateful one (caffeine) show an accent without changing the footprint.
struct ToolbarUtil: View {
    let icon: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? (hover ? Color.primary : Color.secondary.opacity(0.85)))
                .frame(width: 26, height: 26)
                .background(hover ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

/// The reveal affordance: rotates 180° and turns accent when the utility shelf is open.
struct RevealChevron: View {
    let isOpen: Bool
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOpen ? Color.accentColor : (hover ? Color.primary : Color.secondary))
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .frame(width: 26, height: 26)
                .background(hover ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(isOpen ? String(localized: "Hide utilities")
                     : String(localized: "More controls — timeline, theme, activity, setup, health"))
        .accessibilityLabel(String(localized: "More controls"))

        // Keep the button's interaction modifiers together above.
    }
}
