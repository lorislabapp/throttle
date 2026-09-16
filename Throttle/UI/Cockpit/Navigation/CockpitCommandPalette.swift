import SwiftUI

/// ⌘K: one field that reaches every destination, project, session, decision
/// and plan task. Results are grouped by kind so a reader sees what each is
/// before choosing it; ↩ opens the first, Esc closes.
struct CockpitCommandPalette: View {
    @Bindable var cockpit: MultiCockpitModel
    var projects: CockpitProjectsModel

    @State private var query = ""
    @FocusState private var focused: Bool

    enum Group: Int, CaseIterable { case decisions, tasks, projects, sessions, destinations }

    struct Entry: Identifiable {
        let id: String
        let group: Group
        let title: String
        let detail: String
        let perform: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search a project, a session, a decision…"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { results.first.map(run) }
                Text("Esc to close").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let entries = results
                    if entries.isEmpty {
                        Text("Nothing matches.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(Group.allCases, id: \.self) { group in
                        let items = entries.filter { $0.group == group }
                        if !items.isEmpty {
                            Text(verbatim: Self.groupTitle(group))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                            ForEach(items) { entry in
                                Button { run(entry) } label: {
                                    HStack {
                                        Text(verbatim: entry.title).font(.system(size: 13)).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(verbatim: entry.detail).font(.system(size: 11.5))
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onExitCommand { cockpit.isCommandPaletteOpen = false }
    }

    private func run(_ entry: Entry) {
        cockpit.isCommandPaletteOpen = false
        entry.perform()
    }

    // MARK: Index

    private var results: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let all = allEntries
        guard !needle.isEmpty else { return all.filter { $0.group == .destinations || $0.group == .decisions } }
        return all.filter {
            $0.title.localizedStandardContains(needle) || $0.detail.localizedStandardContains(needle)
        }
        .prefix(40).map { $0 }
    }

    private var allEntries: [Entry] {
        var entries: [Entry] = []
        let destinations: [CockpitDestination] = [.today, .sessions, .usage, .portfolio]
        for destination in destinations {
            entries.append(Entry(id: "go:\(destination.title)", group: .destinations, title: destination.title,
                                 detail: String(localized: "Go to")) { cockpit.destination = destination })
        }
        for summary in projects.summaries {
            let path = summary.path
            entries.append(Entry(id: "p:\(path)", group: .projects, title: summary.name,
                                 detail: CockpitNavigationSidebar.projectHint(summary) ?? "") {
                cockpit.destination = .project(path: path)
            })
            for decision in summary.openDecisions {
                entries.append(Entry(id: "d:\(path)#\(decision.id)", group: .decisions, title: decision.title,
                                     detail: summary.name) { cockpit.destination = .project(path: path) })
            }
            for task in summary.overview.tasks {
                entries.append(Entry(id: "t:\(path)#\(task.id)", group: .tasks, title: task.title,
                                     detail: "\(summary.name) · \(ProjectOverviewTab.bucketWord(task.bucket))") {
                    cockpit.pendingPlanSelection = task.id
                    cockpit.destination = .project(path: path)
                })
            }
        }
        for tab in cockpit.sessions {
            entries.append(Entry(id: "s:\(tab.id)", group: .sessions, title: tab.projectName,
                                 detail: tab.needsInput ? String(localized: "waiting for you")
                                    : (tab.isLive ? String(localized: "active") : String(localized: "asleep"))) {
                cockpit.activeID = tab.id
                cockpit.destination = .sessions
            })
        }
        return entries
    }

    private static func groupTitle(_ group: Group) -> String {
        switch group {
        case .decisions: String(localized: "palette.group.decisions", defaultValue: "Decisions")
        case .tasks: String(localized: "palette.group.tasks", defaultValue: "Plan tasks")
        case .projects: String(localized: "palette.group.projects", defaultValue: "Projects")
        case .sessions: String(localized: "palette.group.sessions", defaultValue: "Sessions")
        case .destinations: String(localized: "palette.group.destinations", defaultValue: "Go to")
        }
    }
}
