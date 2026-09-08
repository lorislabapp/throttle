import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct DropdownView: View {
    @Environment(AppState.self) var appState

    enum Mode {
        case meter
        case settings(SettingsTab)
        case stats
        case projects
    }

    enum SettingsTab: String, CaseIterable {
        case general
        case pro
        case assistant
        case calibration
        case hooks
        case about

        /// Terse label for the console tab bar (six must fit at 440pt).
        var tabLabel: String {
            switch self {
            case .general:     return String(localized: "General")
            case .pro:         return String(localized: "Pro")
            case .assistant:   return String(localized: "AI")
            case .calibration: return String(localized: "Caps")
            case .hooks:       return String(localized: "Hooks")
            case .about:       return String(localized: "About")
            }
        }
    }

    @State var mode: Mode = .meter
    @State var embeddedSignedIn: Bool = false

    var body: some View {
        Group {
            if !appState.firstRunDone {
                FirstRunInline()
            } else {
                switch mode {
                case .meter:
                    meterContent
                case .settings(let tab):
                    settingsContent(tab: tab)
                case .stats:
                    StatsInline(onBack: { mode = .meter })
                case .projects:
                    ProjectWindowRoot(onBack: { mode = .meter })
                }
            }
        }
        .padding(meterEdgeToEdge ? 0 : 12)
        .frame(width: dropdownWidth, height: dropdownHeight)
    }

    /// The meter and Stats are native sectioned lists — full-bleed hairline
    /// separators with 16pt internal section padding. Other modes keep the 12pt inset.
    var meterEdgeToEdge: Bool {
        guard appState.firstRunDone else { return true }  // onboarding is edge-to-edge
        switch mode {
        case .meter, .stats, .settings: return true
        default:                        return false
        }
    }

    /// Dropdown grows to a "real window" footprint in projects mode.
    /// MenuBarExtra `.window` style lets the popover size be driven by
    /// the SwiftUI content's frame, so we adjust width + height per mode.
    var dropdownWidth: CGFloat {
        if case .projects = mode { return 860 }
        return 440
    }
    var dropdownHeight: CGFloat? {
        if case .projects = mode { return 540 }
        return nil
    }
}
