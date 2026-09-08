import AppKit
import Observation
import ResearchVaultIngestion
import ResearchVaultIPCModel
import ResearchVaultModel
import ResearchVaultSynthesis
import ResearchVaultXPCClient
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension ResearchVaultWorkbenchView {
    // MARK: - Content

    @ViewBuilder
    var mainContent: some View {
        if !setupComplete {
            setupChecklist
        } else if !model.pendingItems.isEmpty {
            quarantineSection
        } else if model.hasSearched && model.results.isEmpty && pane == .evidence {
            emptyResults
        } else {
            if pane == .evidence, let synthesis = model.synthesis {
                synthesisBlock(synthesis)
            }
            workbenchContent
        }
    }

    var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Three steps to a searchable vault")
                .font(.system(size: 24, weight: .bold))
                .padding(.bottom, 22)

            checklistStep(
                ChecklistStep(
                    number: 1,
                    done: vaultWasRequested,
                    live: !vaultWasRequested,
                    title: String(localized: "Turn on the vault"),
                    detail: String(
                        localized: """
                        A separate signed helper, the Throttle Vault Agent, starts on this Mac. \
                        Nothing leaves the machine.
                        """
                    ),
                    doneTitle: vaultIsOn
                        ? String(localized: "Vault is on")
                        : String(localized: "Vault activation requested")
                )
            ) {
                Button("Turn on the vault") { model.setEnabled(true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            checklistStep(
                ChecklistStep(
                    number: 2,
                    done: vaultIsOn && loginItemsApproved,
                    live: model.serviceState == .requiresApproval,
                    title: String(localized: "Allow it in Login Items, if macOS asks"),
                    detail: model.serviceState == .requiresApproval
                        ? String(localized: "macOS is holding the helper until you approve it.")
                        : String(localized: "If macOS asks, allow the vault in Login Items."),
                    doneTitle: String(localized: "Allowed in Login Items")
                )
            ) {
                Button("Open Login Items") {
                    guard !model.isIsolatedHost else { return }
                    SMAppService.openSystemSettingsLoginItems()
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            checklistStep(
                ChecklistStep(
                    number: 3,
                    done: hasASource,
                    live: vaultIsOn && loginItemsApproved && !hasASource,
                    title: model.selectedSpace.kind == .project
                        ? String(localized: "Add a folder to \(model.selectedSpace.name)")
                        : String(localized: "Add a folder to a space"),
                    detail: stepThreeDetail,
                    doneTitle: String(localized: "Sources connected"),
                    isLast: true
                )
            ) {
                HStack(spacing: 10) {
                    Button("Watch a folder…") { Task { await model.chooseFolderSource() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.selectedSpace.kind != .project)
                    Button("Connect a library…") { Task { await model.connectResearchLibrary() } }
                        .controlSize(.large)
                    Button("Other ways in…") { showAddToVault = true }
                        .controlSize(.large)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, 40)
    }

    /// One step of the setup checklist. Grouped into a value rather than eight
    /// parameters so the call sites read as the three steps they describe.
    struct ChecklistStep {
        let number: Int
        let done: Bool
        let live: Bool
        let title: String
        let detail: String
        let doneTitle: String
        var isLast = false
    }

    @ViewBuilder
    func checklistStep<Action: View>(
        _ step: ChecklistStep,
        @ViewBuilder action: () -> Action
    ) -> some View {
        let (number, done, live) = (step.number, step.done, step.live)
        let (title, detail, doneTitle, isLast) = (step.title, step.detail, step.doneTitle, step.isLast)
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(live ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    .frame(width: 28, height: 28)
                Text(done ? "✓" : "\(number)")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(live ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(done ? doneTitle : title)
                    .font(.system(size: done ? 13 : 17, weight: done ? .medium : .semibold))
                    .foregroundStyle(done || live ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                if !done {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if live { action() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, done ? 12 : 18)
        .overlay(alignment: .bottom) {
            if !isLast { Divider() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Step \(number)"))
    }

    var stepThreeDetail: String {
        guard model.selectedSpace.kind == .project else {
            return String(
                localized: """
                Pick a project in the sidebar first — Portfolio is a read-only roll-up of \
                the other spaces and holds no folders of its own.
                """
            )
        }
        return String(localized: "Pick the folder where this project’s research already lives.")
    }

    var emptyResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing in \(model.selectedSpace.name) matches “\(model.lastQuery)”.")
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(searchedCountSentence)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if model.selectedSpace.kind == .project {
                    Button("Search all of Portfolio instead") {
                        model.selectSpace(ResearchVaultSpace.portfolio.id)
                        Task { await model.search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Try fewer words") { model.query = "" }
                    .controlSize(.large)
            }
            .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, 44)
    }

    /// Only ever states a number the vault actually reported.
    var searchedCountSentence: String {
        guard let documents = model.health?.documentCount, documents > 0 else {
            return String(localized: "This space has no approved documents yet.")
        }
        return String(localized: "\(documents) documents were searched.")
    }

    func synthesisBlock(_ synthesis: ResearchVaultSynthesisDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Text("SYNTHESIS · LOCAL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.2))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(synthesis.answer)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                    Text("Citations: \(synthesis.citationIDs.joined(separator: ", "))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let uncertainty = synthesis.uncertainty, !uncertainty.isEmpty {
                        Text("Uncertainty: \(uncertainty)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }
}
