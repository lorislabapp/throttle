import Foundation

extension TaskIntegrationService {
    static func validateReviewGate(task: PlanTask, state: TaskState) throws {
        guard state.verdictBy != nil else { throw TaskIntegrationError.refused(.ungated) }
        guard task.workContract?.reviewRubric != nil else { return }
        guard let report = state.lastReview,
              (try? WorkflowReviewGate.evaluate(
                  report,
                  task: task,
                  state: state
              ).decision) == .accepted else {
            throw TaskIntegrationError.refused(.ungated)
        }
    }
}
