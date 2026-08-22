import Foundation

/// Remembers which model Anthropic's per-model weekly cap is scoped to.
///
/// ## Why this exists
///
/// Two separate things named that window "Sonnet", and neither had been told
/// so. The UI printed the string `"Weekly · Sonnet only"` unconditionally, and
/// `WindowCalculator` filtered the local estimate with `LIKE '%sonnet%'`.
/// Measured on this account 2026-08-22: the cap sitting at **100%** was scoped
/// to **Fable**. So the loudest number in the app named the wrong model, and
/// the offline estimate behind it counted the wrong events entirely — a row
/// that could read comfortable while the cap it claimed to track was spent.
///
/// The name is in the payload (`limits[].scope.model.display_name`); it was
/// simply thrown away. This stores it the moment the server states it, so both
/// the label and the filter follow the account rather than a constant.
///
/// ## Why it defaults to Sonnet rather than to nothing
///
/// The local estimate predates exact mode and has always meant Sonnet-tier
/// events. Until the server says otherwise, saying "Sonnet only" describes what
/// was actually measured, which is the honest claim. What was never honest was
/// keeping that label after being told a different model.
enum ScopedCapModel {

    private static let key = "scopedCapModelDisplayName"

    /// The display name last stated by the server, or nil if never stated.
    static var displayName: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            guard let newValue, !newValue.isEmpty else {
                UserDefaults.standard.removeObject(forKey: key); return
            }
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    /// Record what the server said. Ignores a nil — a payload that omits the
    /// scope does not un-teach a name we were previously given.
    static func remember(_ name: String?) {
        guard let name, !name.isEmpty, name != displayName else { return }
        displayName = name
    }

    /// The lowercase substring used to match `usage_events.model`. Falls back to
    /// `sonnet` so an install that has never run exact mode keeps computing the
    /// window it always computed.
    static var matchToken: String {
        (displayName ?? "sonnet").lowercased()
    }

    /// "Sonnet only" / "Fable only" — the row subtitle.
    static var subtitle: String { "\(displayName ?? "Sonnet") only" }

    /// "Weekly · Sonnet" / "Weekly · Fable" — the binding label.
    static var bindingLabel: String { "Weekly · \(displayName ?? "Sonnet")" }
}
