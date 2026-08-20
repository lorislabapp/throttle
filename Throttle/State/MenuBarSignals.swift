import Foundation
import SwiftUI

/// Optional signals the always-visible menu-bar item may show, on top of the cap
/// pressure it always shows.
///
/// Cap pressure — the percentage, or the reset countdown once a window is
/// saturated — is deliberately NOT in this list. Throttle exists to stop a
/// session hitting the 5h or weekly cap unwarned; a setting that let the user
/// hide that warning would remove the only thing the menu bar is for. Everything
/// here is context *around* that number, never a replacement for it.
enum MenuBarSignal: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A hidden session is blocked on a question. Swaps the gauge for a bell —
    /// the one signal that outranks pressure, because a stalled session is
    /// burning wall-clock right now while a cap is only a future constraint.
    case waiting
    /// API-equivalent value of the last 7 days. Never subscription spend.
    case cost
    /// Weighted tokens across the weekly window.
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waiting: return String(localized: "Waiting session")
        case .cost:    return String(localized: "Weekly cost")
        case .tokens:  return String(localized: "Weekly tokens")
        }
    }

    var detail: String {
        switch self {
        case .waiting: return String(localized: "Swap the gauge for a bell when a session is blocked on a question.")
        case .cost:    return String(localized: "API-equivalent value of the last 7 days — not what you pay.")
        case .tokens:  return String(localized: "Weighted tokens in the weekly window.")
        }
    }

    /// Fixed render order, most-binding first. Not user-orderable on purpose:
    /// the item is a few characters wide, and letting cost sit left of pressure
    /// would bury the number that matters behind one that doesn't.
    static let renderOrder: [MenuBarSignal] = [.waiting, .cost, .tokens]
}

/// Which optional signals are switched on. Stored as raw strings so an unknown
/// value written by a newer build is ignored rather than crashing an older one.
@MainActor
@Observable
final class MenuBarSignalSettings {
    static let shared = MenuBarSignalSettings()

    private static let key = "menuBarSignals"

    /// `waiting` is on by default — it was the menu bar's behaviour before this
    /// setting existed, and turning it off silently would lose an alert the user
    /// never asked to lose.
    private static let defaults: Set<MenuBarSignal> = [.waiting]

    private(set) var enabled: Set<MenuBarSignal>

    private init() {
        if let raw = UserDefaults.standard.array(forKey: Self.key) as? [String] {
            enabled = Set(raw.compactMap(MenuBarSignal.init(rawValue:)))
        } else {
            enabled = Self.defaults
        }
    }

    func isOn(_ signal: MenuBarSignal) -> Bool { enabled.contains(signal) }

    func set(_ signal: MenuBarSignal, on: Bool) {
        if on { enabled.insert(signal) } else { enabled.remove(signal) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.key)
    }
}
