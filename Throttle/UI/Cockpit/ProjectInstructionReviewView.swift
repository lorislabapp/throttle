import SwiftUI

struct ProjectInstructionReviewView: View {
    let projectRoot: URL

    @Environment(\.dismiss) private var dismiss
    @State private var model = ProjectInstructionModel()
    @State private var target = "AGENTS.md"
    @State private var sectionID = "throttle-project"
    @State private var title = "Project instructions"
    @State private var statement = ""
    @State private var sourceRefs = ""
    @State private var reviewed = false
    @State private var confirmRollback = false

    private let targets = [
        "AGENTS.md",
        "AGENTS.override.md",
        "CLAUDE.md",
        ".github/copilot-instructions.md"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inventory
                    editor
                    if let proposal = model.proposal {
                        exactReview(proposal)
                    }
                    if let receipt = model.receipt {
                        receiptView(receipt)
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 620)
        .task(id: projectRoot.path) { model.bind(to: projectRoot) }
        .onChange(of: model.proposal?.proposedContentDigest) { _, _ in reviewed = false }
        .confirmationDialog(
            "Restore the exact previous instruction file?",
            isPresented: $confirmRollback
        ) {
            Button("Restore previous file", role: .destructive) {
                Task { await model.rollbackLastApply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rollback is refused if the file changed after Throttle applied it.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Instructions").font(.headline)
                Text(projectRoot.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(16)
    }

    private var inventory: some View {
        GroupBox("Applicable sources") {
            VStack(alignment: .leading, spacing: 6) {
                if model.sources.isEmpty {
                    Text("No instruction files discovered.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources, id: \.relativePath) { source in
                        HStack {
                            Image(systemName: source.active ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(source.active ? .green : .secondary)
                            Text(source.relativePath).font(.caption.monospaced())
                            Spacer()
                            Text(source.provider.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let digest = model.snapshotDigest {
                    Text("snapshot \(digest.prefix(12))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var editor: some View {
        GroupBox("Prepare a managed section") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Target", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                TextField("Section identifier", text: $sectionID)
                TextField("Section title", text: $title)
                TextEditor(text: $statement)
                    .font(.body)
                    .frame(minHeight: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                TextField("Source references, comma separated", text: $sourceRefs)
                Button("Prepare exact proposal") {
                    model.prepare(
                        targetRelativePath: target,
                        sectionID: sectionID,
                        title: title,
                        statement: statement,
                        sourceRefs: sourceRefs.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    )
                }
                .disabled(statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private func exactReview(_ proposal: ProjectInstructionProposal) -> some View {
        GroupBox("Exact review") {
            VStack(alignment: .leading, spacing: 10) {
                comparison(title: "Current", text: model.currentContent)
                comparison(title: "Proposed", text: proposal.proposedContent)
                Toggle("I reviewed this exact proposed content", isOn: $reviewed)
                HStack {
                    Button("Apply reviewed proposal") {
                        Task { await model.applyReviewedProposal() }
                    }
                    .disabled(!reviewed || model.isApplying)
                    Text("Writing creates a private proposal, review, backup and receipt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func comparison(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? "(empty file)" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func receiptView(_ receipt: ProjectInstructionApplyReceipt) -> some View {
        GroupBox("Last verified apply") {
            VStack(alignment: .leading, spacing: 6) {
                Text(receipt.appliedContentDigest).font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(receipt.evidenceDirectory).font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Rollback last apply") { confirmRollback = true }
                    .disabled(model.isApplying)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
