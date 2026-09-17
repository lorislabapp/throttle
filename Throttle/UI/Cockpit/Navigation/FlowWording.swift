import SwiftUI

/// Words, symbols and tints for the flow board, kept in one place so Today and
/// the project page name each stage the same way.
enum FlowWording {

    static func title(_ stage: PlanFlow.Stage) -> String {
        switch stage {
        case .toStart: String(localized: "flow.toStart", defaultValue: "To start")
        case .working: String(localized: "flow.working", defaultValue: "Agent working")
        case .fixing: String(localized: "flow.fixing", defaultValue: "To fix")
        case .checking: String(localized: "flow.checking", defaultValue: "Being verified")
        case .ready: String(localized: "flow.ready", defaultValue: "Ready to integrate")
        case .shipped: String(localized: "flow.shipped", defaultValue: "Integrated")
        case .waiting: String(localized: "flow.waiting", defaultValue: "Waiting")
        }
    }

    static func explanation(_ stage: PlanFlow.Stage) -> String {
        switch stage {
        case .toStart:
            String(localized: "flow.toStart.why", defaultValue: "Ready tasks. Open one, then Launch an agent.")
        case .working:
            String(localized: "flow.working.why", defaultValue: "An agent works on these in its own session.")
        case .fixing:
            String(localized: "flow.fixing.why",
                   defaultValue: "Failed or sent back by verification. Throttle relaunches within your budget.")
        case .checking:
            String(localized: "flow.checking.why",
                   defaultValue: "Finished by an agent; tests and a model of another family check them.")
        case .ready:
            String(localized: "flow.ready.why", defaultValue: "Verified. Review the diff, then integrate.")
        case .shipped:
            String(localized: "flow.shipped.why", defaultValue: "Merged into the project.")
        case .waiting:
            String(localized: "flow.waiting.why", defaultValue: "Blocked, or waiting for another task to finish.")
        }
    }

    static func icon(_ stage: PlanFlow.Stage) -> String {
        switch stage {
        case .toStart: "play.circle.fill"
        case .working: "bolt.circle.fill"
        case .fixing: "wrench.and.screwdriver.fill"
        case .checking: "checkmark.shield.fill"
        case .ready: "arrow.triangle.merge"
        case .shipped: "checkmark.circle.fill"
        case .waiting: "hourglass"
        }
    }

    static func tint(_ stage: PlanFlow.Stage) -> Color {
        switch stage {
        case .toStart: .accentColor
        case .working: .blue
        case .fixing: .orange
        case .checking: .purple
        case .ready: .green
        case .shipped: .secondary
        case .waiting: .gray
        }
    }

    static func focusSentence(_ stage: PlanFlow.Stage, _ item: ProjectOverview.TaskItem) -> String {
        let task = "\(item.id) — \(item.title)"
        switch stage {
        case .working:
            let agent = PlanTreeView.runtimeName(item.state.runtime) ?? String(localized: "An agent")
            return String(localized: "\(agent) is working on \(task). Follow it in its session.")
        case .fixing:
            return String(localized: "\(task) needs a fix. Open it to read why.")
        case .checking:
            return String(localized: "\(task) is finished and waits for its verification.")
        case .ready:
            return String(localized: "\(task) is verified. Review it and integrate.")
        case .toStart:
            return String(localized: "Start \(task): open it, then Launch.")
        case .shipped, .waiting:
            return String(localized: "Nothing can start yet: \(task) waits on another task.")
        }
    }

    /// One line under a card when it says something the column does not.
    static func cardNote(_ stage: PlanFlow.Stage, _ item: ProjectOverview.TaskItem, hasSession: Bool) -> String? {
        let state = item.state
        switch stage {
        case .working where !hasSession:
            return String(localized: "flow.note.noSession",
                          defaultValue: "No open session holds it: the agent stopped. Open it to relaunch or release.")
        case .fixing where state.rejectionCount > 0:
            return String(localized: "Sent back \(state.rejectionCount) time(s)")
        case .waiting:
            if let reason = state.blockedReason { return reason }
            guard !item.waitingOn.isEmpty else { return nil }
            let names = item.waitingOn.joined(separator: ", ")
            return String(localized: "Waits for \(names)")
        default:
            return nil
        }
    }

    static func healthLabel(_ check: PlanFlow.HealthCheck) -> String {
        let good = check.verdict == .good
        switch check.kind {
        case .noFailures:
            if good { return String(localized: "flow.health.noFailures", defaultValue: "No failed task") }
            return String(localized: "flow.health.failures", defaultValue: "A task failed")
        case .proofsGreen:
            switch check.verdict {
            case .good: return String(localized: "flow.health.proofs", defaultValue: "Latest tests pass")
            case .problem: return String(localized: "flow.health.proofsRed", defaultValue: "A test run failed")
            case .unknown: return String(localized: "flow.health.proofsNone", defaultValue: "No test run yet")
            }
        case .noDecisionWaiting:
            if good { return String(localized: "flow.health.noDecision", defaultValue: "No decision waits on you") }
            return String(localized: "flow.health.decision", defaultValue: "A decision waits on you")
        case .logIntact:
            if good { return String(localized: "flow.health.log", defaultValue: "Plan log intact") }
            return String(localized: "flow.health.logBroken", defaultValue: "Plan log edited outside Throttle")
        }
    }

    static func healthIcon(_ verdict: PlanFlow.Verdict) -> String {
        switch verdict {
        case .good: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .unknown: "circle.dashed"
        }
    }

    static func healthTint(_ verdict: PlanFlow.Verdict) -> Color {
        switch verdict {
        case .good: .green
        case .problem: .orange
        case .unknown: .secondary
        }
    }
}
