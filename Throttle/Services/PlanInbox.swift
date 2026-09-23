import Foundation

/// The Plan tab's left pane, sorted by who is blocking (design 1b "Inbox"): you,
/// an agent, a dependency — and finished work folded into one line. Phases stay in
/// the plan file and move to the detail's meta line; only leaf tasks are listed,
/// because a phase is never something anyone acts on.
///
/// Pure over the plan and its projected states so the grouping is testable without
/// a view, and so the view never decides status on its own.
enum PlanInbox {

    enum Group: String, CaseIterable, Sendable {
        /// A human is the blocker: review, integrate, verify, launch, or read a failure.
        case needsYou
        case agentsWorking
        /// Blocked on another task, or on a blocker an agent reported.
        case waiting
        case done
    }

    struct Sections: Equatable, Sendable {
        var needsYou: [PlanTask] = []
        var agentsWorking: [PlanTask] = []
        var waiting: [PlanTask] = []
        var done: [PlanTask] = []

        var leafCount: Int { needsYou.count + agentsWorking.count + waiting.count + done.count }

        func tasks(in group: Group) -> [PlanTask] {
            switch group {
            case .needsYou: needsYou
            case .agentsWorking: agentsWorking
            case .waiting: waiting
            case .done: done
            }
        }
    }

    static func sections(plan: Plan, states: [String: TaskState]) -> Sections {
        var out = Sections()
        let leaf = plan.isLeafByID
        for task in displayOrder(plan) where leaf[task.id] == true {
            let state = states[task.id] ?? TaskState()
            let unmet = PlanOrientation.unmetDependencies(for: task, states: states)
            switch group(for: state.status, unmetDependencies: unmet) {
            case .needsYou: out.needsYou.append(task)
            case .agentsWorking: out.agentsWorking.append(task)
            case .waiting: out.waiting.append(task)
            case .done: out.done.append(task)
            }
        }
        return out
    }

    static func group(for status: TaskStatus, unmetDependencies: [String]) -> Group {
        switch status {
        case .integrated: .done
        case .claimed, .running: .agentsWorking
        case .review, .candidate, .done, .failed: .needsYou
        case .blocked: .waiting
        // A ready task waits on the one person who can launch it.
        case .pending: unmetDependencies.isEmpty ? .needsYou : .waiting
        }
    }

    /// Depth-first, the order the plan file gives, so a group reads in plan order.
    static func displayOrder(_ plan: Plan) -> [PlanTask] {
        var out: [PlanTask] = []
        func walk(_ parent: String?) {
            for task in plan.children(of: parent) {
                out.append(task)
                walk(task.id)
            }
        }
        walk(nil)
        return out
    }

    /// The tasks that list `taskID` as a dependency — what finishing it unblocks.
    static func dependents(of taskID: String, in plan: Plan) -> [PlanTask] {
        displayOrder(plan).filter { $0.dependsOn.contains(taskID) }
    }

    /// "Map the codebase: entry points…" → "Map the codebase". Titles are written
    /// as "short name: explanation"; lists and "after …" lines use the short name.
    static func shortTitle(_ title: String) -> String {
        guard let colon = title.firstIndex(of: ":") else { return title }
        let head = title[..<colon].trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? title : head
    }

    /// "after Competitors", "after 2 tasks" — never a task id.
    static func afterText(_ unmet: [String], in plan: Plan) -> String? {
        switch unmet.count {
        case 0: return nil
        case 1:
            let name = plan.task(unmet[0]).map { shortTitle($0.title) } ?? String(localized: "another task")
            return String(localized: "after \(name)")
        default: return String(localized: "after \(unmet.count) tasks")
        }
    }
}
