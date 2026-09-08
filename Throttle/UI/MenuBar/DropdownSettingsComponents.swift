import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct SettingsHair: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1).padding(.horizontal, 16)
    }
}

struct SettingsGroupHeader: View {
    let label: String
    var desc: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(label)).font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9).textCase(.uppercase).foregroundStyle(.tertiary)
            if let desc {
                Text(LocalizedStringKey(desc)).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 3)
    }
}

/// Flat ≥44pt settings row: title (+ optional sub) left, a trailing control right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var sub: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 13))
                if let sub {
                    Text(LocalizedStringKey(sub)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

/// Quiet caption under a group, full-bleed with 16pt padding.
struct SettingsNote: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
    }
}

/// Bordered settings button (`.primary` = accent fill). Calm, native-ish.
struct SettingsButton: View {
    let title: String
    var systemImage: String?
    var primary: Bool = false
    var role: ButtonRole?
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(LocalizedStringKey(title))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(primary ? AnyShapeStyle(Color.white)
                             : AnyShapeStyle(role == .destructive ? Color.red : Color.primary))
            .background {
                if primary { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) } else { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - First-run inline view

/// First-run onboarding — "The Living Meter" (Direction C). The real meter sits
/// at the top, empty and ghosted, and fills in as the user answers; each answer
/// collapses to a confirmed row. Onboarding IS the product. See UI-SPEC-onboarding.md.
