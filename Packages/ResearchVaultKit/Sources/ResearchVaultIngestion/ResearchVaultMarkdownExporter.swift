import Foundation
import ResearchVaultModel

public struct ResearchVaultMarkdownDocument: Equatable, Sendable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}

public enum ResearchVaultMarkdownExporter {
    public static func export(
        _ receipts: [ResearchReceipt]
    ) -> [ResearchVaultMarkdownDocument] {
        receipts.sorted { $0.receiptID < $1.receiptID }.map { receipt in
            ResearchVaultMarkdownDocument(
                filename: receipt.projectKey + "--" + receipt.receiptID + ".md",
                content: markdown(receipt)
            )
        }
    }

    private static func markdown(_ receipt: ResearchReceipt) -> String {
        var lines = [
            "---",
            "receipt_id: " + yaml(receipt.receiptID),
            "project_key: " + yaml(receipt.projectKey),
            "sensitivity: " + yaml(receipt.sensitivity.rawValue),
            "created_at: " + yaml(timestamp(receipt.createdAt)),
            "content_sha256: " + yaml(receipt.contentHash),
            "session_id: " + yaml(receipt.sessionID),
            "agent_id: " + yaml(receipt.agentID)
        ]
        if let parentAgentID = receipt.parentAgentID {
            lines.append("parent_agent_id: " + yaml(parentAgentID))
        }
        lines.append("sources:")
        if receipt.sources.isEmpty {
            lines.append("  []")
        } else {
            for source in receipt.sources {
                lines.append("  - id: " + yaml(source.id))
                lines.append("    kind: " + yaml(source.kind.rawValue))
                lines.append("    locator: " + yaml(source.locator))
                lines.append("    observed_at: " + yaml(timestamp(source.observedAt)))
                lines.append("    sha256: " + yaml(source.sha256))
            }
        }
        appendFindings(receipt, to: &lines)
        appendOpenQuestions(receipt, to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendFindings(_ receipt: ResearchReceipt, to lines: inout [String]) {
        lines.append(contentsOf: ["---", "", "# " + receipt.question, "", "## Findings", ""])
        if receipt.findings.isEmpty {
            lines.append("_No findings._")
        } else {
            for (index, finding) in receipt.findings.enumerated() {
                lines.append("### " + String(index + 1))
                lines.append("")
                lines.append("- status: " + yaml(finding.status.rawValue.lowercased()))
                let evidence = finding.evidenceIDs.map(yaml).joined(separator: ", ")
                lines.append("- evidence_ids: [" + evidence + "]")
                lines.append("")
                lines.append(finding.claim)
                lines.append("")
            }
        }
    }

    private static func appendOpenQuestions(_ receipt: ResearchReceipt, to lines: inout [String]) {
        guard !receipt.openQuestions.isEmpty else { return }
        lines.append(contentsOf: ["## Open questions", ""])
        lines.append(contentsOf: receipt.openQuestions.map { "- " + $0 })
        lines.append("")
    }

    private static func timestamp(_ date: Date) -> String {
        date.ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
    }

    private static func yaml(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
