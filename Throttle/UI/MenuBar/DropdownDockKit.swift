import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

enum DockBadgeStyle { case pro, beta }

/// Tiny floating badge over a dock tile. `.pro` = soft graphite fill (only when
/// Free); `.beta` = transparent with a hairline border — matching the title
/// pills' exact-vs-estimate restraint (no accent, no colour).
struct DockBadgeView: View {
    let text: String
    let style: DockBadgeStyle
    var body: some View {
        Group {
            switch style {
            case .pro:
                Text(text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            case .beta:
                Text(text)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(.tertiary)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
        }
        .font(.system(size: 8.5, weight: .heavy))
        .tracking(0.4)
    }
}

/// One destination tile in the dock: icon over a small label, a subtle hover
/// fill, and an optional floating badge. Uses `onTapGesture` + `onHover`
/// (the macOS-preferred pattern over Button for hover-reactive cells).
struct DockTile: View {
    let icon: String
    let label: LocalizedStringKey
    var badgeText: String?
    var badgeStyle: DockBadgeStyle = .beta
    let action: () -> Void
    @State var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.primary)
                .opacity(0.82)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hover ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .top) {
            if let badgeText {
                DockBadgeView(text: badgeText, style: badgeStyle)
                    .offset(x: 14, y: -1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings cockpit kit
