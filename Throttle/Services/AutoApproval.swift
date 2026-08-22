import Foundation

/// The switch for rule-based prompt answering.
///
/// Separate from `ApprovalRuleService` on purpose: the rules are pure and
/// testable, and whether they are allowed to act is a user decision that lives
/// somewhere else. Off until the user turns it on, and off again on every fresh
/// install — an automation that answers on your behalf should never arrive
/// already switched on.
enum AutoApproval {
    private static let key = "autoApproveReadOnlyPrompts"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
