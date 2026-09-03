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
        /// A family Throttle has no rule for yet: match one derived *word*
        /// inside the model id. Never the whole display name — see
        /// `familyToken(in:)`. A cap on a model we cannot name yet must still
        /// be counted, not dropped.
        case nameToken(String)
    }

    /// The match for whatever the server last stated.
    static var match: Match { match(forDisplayName: displayName) }

    /// Falls back to Sonnet when nothing usable has been stated, so an install
    /// that has never run exact mode keeps computing the window it always
    /// computed.
    ///
    /// ## The scope is family-level, deliberately
    ///
    /// A cap the server names `"Opus 4.7"` resolves to `.family(.opus)` and
    /// therefore counts Opus 4.6 events too. Anthropic scopes these caps by
    /// model *family*, ids do not carry a stable generation we could match on,
    /// and the direction of error is over-report — the meter says you are
    /// closer to the cap than you are. For a thing whose job is to stop you
    /// hitting a wall, that is the safe direction; under-reporting is the one
    /// that lies. Written down because it is a choice, not an accident.
    static func match(forDisplayName name: String?) -> Match {
        guard let name, !name.isEmpty else { return .family(.sonnet) }
        let tier = ModelTier.from(modelString: name)
        if tier != .other { return .family(tier) }
        guard let token = familyToken(in: name) else { return .family(.sonnet) }
        return .nameToken(token)
    }

    /// The one word from a display name that could plausibly appear in a model
    /// id, or nil if none does.
    ///
    /// The whole name must never be used. `"Claude Zephyr 1.0"` as
    /// `LIKE '%claude zephyr 1.0%'` matches nothing against `claude-zephyr-1`,
    /// which is the silent-zero this type exists to end — 0 tokens used and a
    /// full week remaining on the window that means "you are out". A bare
    /// `"Claude"` is the opposite hazard: it matches every row and charges the
    /// whole account against a per-model cap.
    ///
    /// So: lowercase, split on non-letters (which drops `4.7`, `1.0`, hyphens),
    /// discard the vendor word and anything too short to be a family name, and
    /// take the longest survivor. `%` and `_` cannot survive an
    /// alphabetics-only filter, so a server-supplied LIKE wildcard cannot widen
    /// the match.
    static func familyToken(in name: String) -> String? {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0 != "claude" && $0 != "anthropic" && $0.count >= 3 }
            .max(by: { $0.count < $1.count })
    }

    private static let unmatchedKey = "scopedCapTokenMatchedNothing"

    /// True when the derived token was checked against the database and
    /// selected nothing over a window that had events — see
    /// `WindowCalculator.resolveScope`. The window then computes the documented
    /// default, and the labels below say so instead of naming a model whose
    /// events were never counted.
    static var tokenMatchedNothing: Bool {
        get { UserDefaults.standard.bool(forKey: unmatchedKey) }
        set { UserDefaults.standard.set(newValue, forKey: unmatchedKey) }
    }

    /// Record the outcome of that check. Cheap and idempotent; only writes on a
    /// change so it does not churn the defaults file on every snapshot tick.
    static func recordTokenMatchedNothing(_ value: Bool) {
        guard value != tokenMatchedNothing else { return }
        tokenMatchedNothing = value
        let state = value ? "matched nothing — using default Sonnet scope" : "matches events again"
        AppLogger.app.notice("scoped cap token \(state, privacy: .public)")
    }

    /// The name to put on the window, or nil when the window is computing the
    /// default rather than the model the server named.
    private static var effectiveName: String? {
        guard let displayName, !tokenMatchedNothing else { return nil }
        return displayName
    }

    /// "Sonnet only" / "Fable only" — the row subtitle. When the named model
    /// matched no event, this says the default is what is being measured; a row
    /// that keeps a name it is not counting is what started all of this.
    static var subtitle: String {
        guard let name = effectiveName else {
            return tokenMatchedNothing ? "Sonnet only (default)" : "Sonnet only"
        }
        return "\(name) only"
    }

    /// "Weekly · Sonnet" / "Weekly · Fable" — the binding label.
    static var bindingLabel: String { "Weekly · \(effectiveName ?? "Sonnet")" }
}
