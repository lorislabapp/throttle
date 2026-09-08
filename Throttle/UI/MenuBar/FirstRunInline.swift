import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct FirstRunInline: View {
    @Environment(AppState.self) var appState

    enum PlanChoice: String, CaseIterable, Identifiable {
        case pro, max5x, max20x, skip
        var id: String { rawValue }
        var name: String {
            switch self {
            case .pro:    return "Pro"
            case .max5x:  return "Max 5×"
            case .max20x: return "Max 20×"
            case .skip:   return String(localized: "Skip — auto-calibrate")
            }
        }
        var price: String? {
            switch self {
            case .pro: return "€19/mo"; case .max5x: return "€90/mo"
            case .max20x: return "€180/mo"; case .skip: return nil
            }
        }
        var blurb: String {
            switch self {
            case .pro:    return String(localized: "Most solo developers")
            case .max5x:  return String(localized: "Heavy daily Claude Code")
            case .max20x: return String(localized: "All-day, multi-agent")
            case .skip:   return String(localized: "Throttle learns your caps from real usage over a few days.")
            }
        }
        /// Display caps — mirror the real presets written in `apply()`.
        var session: String? {
            switch self { case .pro: return "4M"; case .max5x: return "8M"; case .max20x: return "20M"; case .skip: return nil }
        }
        var weekly: String? {
            switch self { case .pro: return "60M"; case .max5x: return "200M"; case .max20x: return "800M"; case .skip: return nil }
        }
    }

    @State var pick: PlanChoice?
    @State var enableLoginItems: Bool = true
    @State var signedIn: Bool = false
    /// Conversational step: 0 = ask plan, 1 = ask launch, 2 = done.
    @State var qi: Int = 0

    let demo = (session: 0.47, weekly: 0.12, sonnet: 0.03)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHero
            livingMeter
            progressDots
            thread
        }
        .task { signedIn = ExactModeService.shared.hasFreshSnapshot }
    }

    var brandHero: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 26)).foregroundStyle(.primary.opacity(0.9))
                .padding(.bottom, 8)
            Text("Throttle").font(.system(size: 17, weight: .semibold))
            Text("Accurate Claude Code usage, in your menu bar.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 4)
    }

    // MARK: - Living meter preview

    var livingMeter: some View {
        let filled = pick != nil
        let auto = pick == .skip
        return VStack(alignment: .leading, spacing: 0) {
            Text("YOUR METER")
                .font(.system(size: 8.5, weight: .heavy)).tracking(1)
                .foregroundStyle(.tertiary).padding(.bottom, 9)
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 14)).foregroundStyle(.primary.opacity(0.9))
                Text("Throttle").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if filled {
                    Text(auto ? "AUTO" : "PRO").font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)
            meterRow("Session", "5-hour", cap: pick?.session, pct: demo.session, auto: auto, filled: filled)
            meterDivider
            meterRow("Weekly", "all models", cap: pick?.weekly, pct: demo.weekly, auto: auto, filled: filled)
            meterDivider
            meterRow("Weekly", ScopedCapModel.subtitle, cap: pick?.weekly, pct: demo.sonnet, auto: auto, filled: filled)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .animation(.easeOut(duration: 0.55), value: pick)
    }

    var meterDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }

    @ViewBuilder
    func meterRow(_ name: String, _ sub: String, cap: String?, pct: Double, auto: Bool, filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name).font(.system(size: 12, weight: .medium)).opacity(filled ? 1 : 0.5)
                Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).opacity(filled ? 1 : 0.5)
                Spacer(minLength: 0)
                if filled {
                    Text(auto ? "auto" : "cap \(cap ?? "")")
                        .font(.system(size: 11).monospaced()).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "— —").font(.system(size: 11).monospaced()).foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    if filled {
                        Capsule().fill(Color.primary.opacity(auto ? 0.28 : 0.45))
                            .frame(width: auto ? geo.size.width : max(4, geo.size.width * pct))
                    }
                }
            }
            .frame(height: 5)
        }
        .padding(.vertical, 8)
    }

    var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(qi >= i ? Color.accentColor : Color.primary.opacity(0.10)).frame(height: 3)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: - Conversational thread

    @ViewBuilder
    var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            if qi >= 1 {
                confirmedRow(label: "Plan", value: planSummary) { withAnimation { qi = 0 } }
            }
            if qi == 0 {
                qCard("Which Claude plan are you on?",
                      "Pick one and watch your meter fill in. Reads ~/.claude/projects on this Mac.")
                planPicker
            } else if qi == 1 {
                qCard("Keep Throttle in your menu bar?", "Launch it automatically when you log in.")
                launchRow
                actionBar("Looks good") { withAnimation { qi = 2 } }
            } else {
                confirmedRow(label: "Launch at login", value: enableLoginItems ? "On" : "Off") { withAnimation { qi = 1 } }
                exactTeaser
                actionBar("Open my meter") { apply() }
            }
        }
    }

    var planSummary: String {
        guard let p = pick else { return String(localized: "Auto-calibrate") }
        if let s = p.session, let w = p.weekly { return "\(p.name) · \(s)/\(w)" }
        return p.name
    }

    func qCard(_ prompt: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prompt).font(.system(size: 14, weight: .semibold))
            Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 6)
    }

    var planPicker: some View {
        VStack(spacing: 6) {
            ForEach(PlanChoice.allCases) { planButton($0) }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4)
    }
}
