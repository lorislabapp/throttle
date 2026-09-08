import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension FirstRunInline {
    @ViewBuilder
    func planButton(_ p: PlanChoice) -> some View {
        let on = pick == p
        Button {
            withAnimation(.easeOut(duration: 0.5)) { pick = p; qi = 1 }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    if on {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(p.name).font(.system(size: 13.5, weight: .medium))
                        if let price = p.price {
                            Text(price).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Text(p.blurb).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let s = p.session, let w = p.weekly {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(s) · \(w)").font(.system(size: 13).monospaced())
                        Text("SESSION · WEEKLY").font(.system(size: 8.5, weight: .medium)).tracking(0.4)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11).fill(on ? Color.accentColor.opacity(0.07) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                        on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func confirmedRow(label: String, value: String, onEdit: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 17, height: 17)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .medium))
            Button { onEdit() } label: {
                Text("Edit").font(.system(size: 11)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 16) }
    }

    var launchRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at login").font(.system(size: 13))
                Text("Keep the meter in your menu bar.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $enableLoginItems).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    var exactTeaser: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.tertiary)
            (Text("Want server-true numbers? Turn on ").foregroundStyle(.tertiary)
             + Text("Exact mode").foregroundStyle(.secondary).fontWeight(.semibold)
             + Text(" later in Settings.").foregroundStyle(.tertiary))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    func actionBar(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    func apply() {
        if enableLoginItems { try? LoginItemService.setEnabled(true) }
        let preset: [(WindowKind, Int)]? = {
            switch pick {
            case .pro:    return [(.session5h, 4_000_000), (.weeklyAll, 60_000_000), (.weeklySonnet, 60_000_000)]
            case .max5x:  return [(.session5h, 8_000_000), (.weeklyAll, 200_000_000), (.weeklySonnet, 200_000_000)]
            case .max20x: return [(.session5h, 20_000_000), (.weeklyAll, 800_000_000), (.weeklySonnet, 800_000_000)]
            case .skip, .none: return nil
            }
        }()
        if let preset,
           let url = try? DatabaseManager.databaseURL(),
           let pool = try? DatabasePool(path: url.path) {
            try? pool.write { db in
                for (kind, cap) in preset {
                    try CalibrationEngine.setManual(in: db, kind: kind, capTokens: cap)
                }
            }
        }
        appState.markFirstRunDone()
        appState.refresh()
        if signedIn {
            appState.setExactModeEnabled(true)
            ExactModeService.shared.start()
        }
    }
}
