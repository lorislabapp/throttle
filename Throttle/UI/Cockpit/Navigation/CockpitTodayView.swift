import SwiftUI

/// The Cockpit's landing page. It lists what waits on the person first —
/// sessions with a question, decisions nobody settled, blocked work — then the
/// projects with their verified progress, then the quota. Everything else is
/// one click or ⌘K away.
struct CockpitTodayView: View {
    @Bindable var cockpit: MultiCockpitModel
    var projects: CockpitProjectsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                OnboardingChecklistCard(cockpit: cockpit, projects: projects)
                waitingCard
                TodayFlowTiles(cockpit: cockpit, projects: projects)
                projectsCard
                quotaCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CockpitDestination.today.title).font(.system(size: 22, weight: .bold))
                Text(verbatim: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { cockpit.isCommandPaletteOpen = true } label: {
                Label(String(localized: "Search a project, a session…"), systemImage: "magnifyingglass")
            }
        }
    }

    // MARK: Waiting

    private enum WaitingKind { case question, decision, blocked }

    private struct WaitingItem: Identifiable {
        let id: String
        let kind: WaitingKind
        let title: String
        let context: String
        let action: () -> Void
    }

    private var waitingItems: [WaitingItem] {
        var items: [WaitingItem] = cockpit.sessions.filter(\.needsInput).map { tab in
            WaitingItem(id: "q:\(tab.id)", kind: .question,
                        title: tab.latestQuestion.map { "« \($0) »" }
                            ?? String(localized: "A session is waiting for you"),
                        context: tab.projectName) {
                cockpit.activeID = tab.id
                cockpit.destination = .sessions
            }
        }
        for summary in projects.summaries {
            for decision in summary.openDecisions {
                items.append(WaitingItem(id: "d:\(summary.path)#\(decision.id)", kind: .decision,
                                         title: decision.title, context: summary.name) {
                    cockpit.destination = .project(path: summary.path)
                })
            }
            if summary.blockedCount > 0 {
                items.append(WaitingItem(id: "b:\(summary.path)", kind: .blocked,
                                         title: String(localized: "\(summary.blockedCount) task(s) blocked or failed"),
                                         context: summary.name) {
                    cockpit.destination = .project(path: summary.path)
                })
            }
        }
        return items
    }

    private var waitingCard: some View {
        let items = waitingItems
        return card(title: String(localized: "What waits on you"),
                    trailing: items.isEmpty ? nil : String(localized: "\(items.count) item(s) · all projects")) {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing waits on you").font(.system(size: 14, weight: .semibold))
                    Text("You will see it here as soon as a session asks a question or a decision is needed.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 14) {
                    Text(Self.kindWord(item.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.kind == .blocked ? Color.orange : Color.accentColor)
                        .frame(width: 80, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                        Text(verbatim: item.context).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(Self.actionWord(item.kind), action: item.action).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
            }
        }
    }

    // MARK: Projects and quota

    private var projectsCard: some View {
        card(title: String(localized: "Projects"),
             trailing: String(localized: "progress verified by tests, not declared")) {
            if projects.summaries.isEmpty {
                Text("No project has a plan yet. Open a session in a project folder, then choose Plan to start one.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).padding(16)
            }
            ForEach(projects.summaries) { summary in
                Button { cockpit.destination = .project(path: summary.path) } label: {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: summary.name).font(.system(size: 13.5, weight: .semibold))
                            if let objective = summary.overview?.objective?.text {
                                Text(verbatim: objective).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(verbatim: CockpitNavigationSidebar.projectHint(summary) ?? "")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    @ViewBuilder
    private var quotaCard: some View {
        if let binding = cockpit.binding {
            card(title: String(localized: "Subscription quota"), trailing: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: binding.name).font(.system(size: 13))
                        Spacer()
                        Text(verbatim: "\(binding.estimate ? "≈" : "")\(binding.pct) %")
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                    ProgressView(value: Double(min(binding.pct, 100)), total: 100)
                    Text("Renews \(binding.reset) · subscription, not billed per use")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Button("Details in Usage and costs") { cockpit.destination = .usage }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                .padding(16)
            }
        }
    }

    // MARK: Parts

    private func card<Content: View>(title: String, trailing: String?,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if let trailing { Text(verbatim: trailing).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider()
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10)))
    }

    private static func kindWord(_ kind: WaitingKind) -> String {
        switch kind {
        case .question: String(localized: "today.kind.question", defaultValue: "Question")
        case .decision: String(localized: "today.kind.decision", defaultValue: "Decision")
        case .blocked: String(localized: "today.kind.blocked", defaultValue: "Blocked")
        }
    }

    private static func actionWord(_ kind: WaitingKind) -> String {
        switch kind {
        case .question: String(localized: "today.action.answer", defaultValue: "Answer")
        case .decision: String(localized: "today.action.settle", defaultValue: "Settle")
        case .blocked: String(localized: "today.action.open", defaultValue: "Open the project")
        }
    }
}
