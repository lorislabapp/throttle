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

    /// How the scoped weekly window selects rows from `usage_events`.
    ///
    /// This used to be the display name itself, lowercased, dropped straight
    /// into `LIKE '%…%'`. It worked for `"Fable"` only because that word happens
    /// to be a substring of `claude-fable-5`. A name that is not a bare family
    /// word — `"Claude Sonnet 4.6"` against the id `claude-sonnet-4-6` — matched
    /// nothing, and matching nothing here is not a visible error: the total
    /// reads 0 and the reset reads a full week, so the one window whose job is
    /// to say "you are out" would say "untouched".
    enum Match: Equatable, Sendable {
        /// A family Throttle knows, with its aliases — `fable` also covers
        /// `mythos`, which a substring of either name could never do.
        case family(ModelTier)
        /// A family Throttle has no rule for yet: match the name inside the
        /// model id, which is how ids are built. A cap on a model we cannot
        /// name yet must still be counted, not dropped.
        case nameToken(String)
    }

    /// The match for whatever the server last stated.
    static var match: Match { match(forDisplayName: displayName) }

    /// Falls back to Sonnet when nothing has been stated, so an install that has
    /// never run exact mode keeps computing the window it always computed.
    static func match(forDisplayName name: String?) -> Match {
        guard let name, !name.isEmpty else { return .family(.sonnet) }
        let tier = ModelTier.from(modelString: name)
        if tier != .other { return .family(tier) }
        // `%` and `_` are stripped: the name is server-supplied, and a LIKE
        // wildcard in it would silently widen the filter to uncapped models.
        let safe = name.lowercased().filter { $0 != "%" && $0 != "_" }
        return safe.isEmpty ? .family(.sonnet) : .nameToken(safe)
    }

    /// "Sonnet only" / "Fable only" — the row subtitle.
    static var subtitle: String { "\(displayName ?? "Sonnet") only" }

    /// "Weekly · Sonnet" / "Weekly · Fable" — the binding label.
    static var bindingLabel: String { "Weekly · \(displayName ?? "Sonnet")" }
}
