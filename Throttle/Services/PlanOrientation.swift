import Foundation

/// Pure orientation rules for the Plan UI. A user opening Plan should land on
/// the task that explains the session they are looking at, or on work they can
/// actually start — never on an arbitrary phase header.
enum PlanOrientation {

    static func initialSelection(plan: Plan, states: [String: TaskState],
                                 activeMissionID: String?) -> String? {
        let ordered = depthFirstTasks(plan)

        if let activeMissionID,
           let owned = ordered.first(where: { states[$0.id]?.missionID == activeMissionID }) {
            return owned.id
        }

        if let ready = ordered.first(where: {
            plan.isLeafByID[$0.id] == true
                && states[$0.id]?.status == .pending
                && states[$0.id]?.owner == nil
                && unmetDependencies(for: $0, states: states).isEmpty
        }) {
            return ready.id
        }

        if let unfinished = ordered.first(where: {
            plan.isLeafByID[$0.id] == true
                && !isFinished(states[$0.id]?.status ?? .pending)
        }) {
            return unfinished.id
        }

        return ordered.first?.id
    }

    static func unmetDependencies(for task: PlanTask,
                                   states: [String: TaskState]) -> [String] {
        task.dependsOn.filter { !isFinished(states[$0]?.status ?? .pending) }
    }

    private static func isFinished(_ status: TaskStatus) -> Bool {
        status == .done || status == .integrated
    }

    private static func depthFirstTasks(_ plan: Plan) -> [PlanTask] {
        var result: [PlanTask] = []
        func walk(_ parent: String?) {
            for task in plan.children(of: parent) {
                result.append(task)
                walk(task.id)
            }
        }
        walk(nil)
        return result
    }
}
