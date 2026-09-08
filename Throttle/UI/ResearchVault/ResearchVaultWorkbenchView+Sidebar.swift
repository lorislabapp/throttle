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
    // MARK: - Sidebar

    var facetCounts: [WorkbenchPane: Int] {
        let receipts = scopedApprovedReceipts
        return [
            .evidence: model.results.count,
            .sources: ResearchVaultWorkbenchProjection.sources(receipts: receipts).count,
            .claims: ResearchVaultWorkbenchProjection.claims(receipts: receipts).count,
            .timeline: receipts.count,
            .revisions: ResearchVaultWorkbenchProjection.revisions(receipts: receipts).count,
            .reasoning: model.reasoningFacts.count
        ]
    }

    var spaceSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarHeader("Spaces")
                ForEach(model.spaces) { space in
                    spaceRow(space)
                    if space.id == model.selectedSpaceID && space.kind == .project {
                        selectedSpaceFolders
                    }
                }

                sidebarHeader(model.hasSearched ? "Facets · this query" : "Facets")
                ForEach(WorkbenchPane.allCases) { facet in
                    facetRow(facet)
                }

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .background(.quaternary.opacity(0.2))
    }

    func sidebarHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    func spaceRow(_ space: ResearchVaultSpace) -> some View {
        let selected = space.id == model.selectedSpaceID
        let waiting = selected ? model.pendingItems.count : 0
        return Button {
            model.selectSpace(space.id)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
                Text(space.name).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if waiting > 0 {
                    Text("\(waiting) waiting")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The folders of the selected space, and the control that adds one — in the
    /// space they belong to, rather than behind an unlabelled icon in a header.
    @ViewBuilder
    var selectedSpaceFolders: some View {
        if spaceFolders.isEmpty {
            Text("No folders yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 25)
                .padding(.vertical, 2)
        }
        ForEach(spaceFolders) { source in
            HStack(spacing: 6) {
                Text(source.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Button {
                    model.removeFolderSource(source.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(source.name)")
            }
            .padding(.leading, 25)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
        }
        Button {
            Task { await model.chooseFolderSource() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "plus")
                Text("Add folder to \(model.selectedSpace.name)…")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.leading, 25)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!vaultIsOn)
        .help(vaultIsOn
            ? String(localized: "Watch a folder for this space")
            : String(localized: "Turn the vault on first"))
    }

    func facetRow(_ facet: WorkbenchPane) -> some View {
        let selected = pane == facet
        let count = facetCounts[facet] ?? 0
        return Button {
            pane = facet
        } label: {
            HStack {
                Text(facet.localizedTitle)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                Text(model.hasSearched || count > 0 ? "\(count)" : "—")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
            .background(
                selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var scopedApprovedReceipts: [ResearchReceipt] {
        let scope = Set(model.selectedProjectKeys)
        return model.approvedReceipts.filter { scope.contains($0.projectKey) }
    }

    @ViewBuilder
    var workbenchContent: some View {
        switch pane {
        case .evidence where model.results.isEmpty:
                ContentUnavailableView(
                    "Source-first local research",
                    systemImage: "lock.doc",
                    // swiftlint:disable:next line_length
                    description: Text("Search returns bounded excerpts with path, locator, hash, freshness and evidence status.")
                )
        case .evidence:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { index, item in
                        resultCard(item, identifier: "S\(index + 1)")
                    }
                }
                .padding(16)
            }
        case .sources:
            sourceList
        case .claims:
            claimList
        case .timeline:
            timelineList
        case .revisions:
            revisionList
        case .reasoning:
            reasoningList
        }
    }
}
