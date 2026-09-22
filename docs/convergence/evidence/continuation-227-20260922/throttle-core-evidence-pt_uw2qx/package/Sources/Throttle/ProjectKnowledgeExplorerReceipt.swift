import Foundation

extension ProjectKnowledgeExplorer {
    func receipt(
        operation: ProjectKnowledgeOperation,
        accesses: [ProjectKnowledgeAccess],
        redactions: [String] = [],
        truncated: Bool,
        limits: [String: Int],
        now: Date
    ) -> ProjectKnowledgeReceipt {
        ProjectKnowledgeReceipt(
            id: UUID(),
            operation: operation,
            projectRoot: root.path,
            createdAt: now,
            accesses: accesses,
            redactions: Array(Set(redactions)).sorted(),
            truncated: truncated,
            limits: limits
        )
    }
}
