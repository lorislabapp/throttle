import Foundation
import TipKit

/// The first-run path through the product, as a checklist that ticks itself
/// when the person actually does each step — never by reading a slide.
enum CockpitOnboarding {

    enum Step: String, CaseIterable, Identifiable, Sendable {
        case openProject, createPlan, launchTask, followSession, settleDecision
        var id: String { rawValue }
    }

    static let dismissedKey = "cockpitOnboarding.dismissed"
    private static func key(_ step: Step) -> String { "cockpitOnboarding.done.\(step.rawValue)" }

    /// A step counts as done when it was recorded, or when the state it leads to
    /// already exists (a plan on disk means "create a plan" is done, whoever did it).
    static func completed(hasPlan: Bool, hasSettledDecision: Bool,
                          defaults: UserDefaults = .standard) -> Set<Step> {
        var done = Set(Step.allCases.filter { defaults.bool(forKey: key($0)) })
        if hasPlan { done.insert(.createPlan) }
        if hasSettledDecision { done.insert(.settleDecision) }
        return done
    }

    /// The first step not done yet, in path order.
    static func current(in done: Set<Step>) -> Step? {
        Step.allCases.first { !done.contains($0) }
    }

    @MainActor
    static func markDone(_ step: Step, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key(step)) else { return }
        defaults.set(true, forKey: key(step))
        OnboardingTips.currentStep = current(in: completed(hasPlan: false, hasSettledDecision: false,
                                                           defaults: defaults))?.rawValue ?? ""
    }

    static func isDismissed(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: dismissedKey) }
    static func dismiss(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: dismissedKey) }
}

// MARK: - Tips

/// Bubbles that point at the one control the current step needs. They only
/// show while that step is the current one, so they never pile up.
enum OnboardingTips {
    @Parameter static var currentStep: String = ""

    static func configure() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

struct OpenProjectTip: Tip {
    var title: Text { Text("Open a project") }
    var message: Text? { Text("Each project gathers its plan, its sessions and what waits on you.") }
    var image: Image? { Image(systemName: "folder") }
    var rules: [Rule] {
        #Rule(OnboardingTips.$currentStep) { $0 == "openProject" }   // #Rule needs a literal: Step.openProject
    }
}

struct LaunchTaskTip: Tip {
    var title: Text { Text("Launch an agent on this task") }
    var message: Text? {
        Text("Pick a ready task, then Launch. Throttle opens a session that works on it and reports back here.")
    }
    var image: Image? { Image(systemName: "play.circle") }
    var rules: [Rule] {
        #Rule(OnboardingTips.$currentStep) { $0 == "launchTask" }   // #Rule needs a literal: Step.launchTask
    }
}

struct SettleDecisionTip: Tip {
    var title: Text { Text("Settle it here") }
    var message: Text? { Text("Your choice and your reason go into the task's log.") }
    var image: Image? { Image(systemName: "checkmark.seal") }
    var rules: [Rule] {
        #Rule(OnboardingTips.$currentStep) { $0 == "settleDecision" }   // #Rule needs a literal: Step.settleDecision
    }
}
