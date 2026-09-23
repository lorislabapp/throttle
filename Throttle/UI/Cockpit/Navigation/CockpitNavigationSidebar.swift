import AppKit
import SwiftUI
import TipKit

/// The Cockpit's left column: four destinations always in view, projects under
/// their own heading. It answers "where do I go" before anything else is shown.
struct CockpitNavigationSidebar: View {
    @Environment(AppState.self) private var appState
    @Bindable var cockpit: MultiCockpitModel
    var projects: CockpitProjectsModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.today, icon: "sun.max", badge: todayCount > 0 ? "\(todayCount)" : nil)

                    sectionHeader("cockpit.nav.projects", "Projects")
                        .popoverTip(OpenProjectTip(), arrowEdge: .trailing)
                    if projects.summaries.isEmpty {
                        Text(projects.isLoading
                             ? String(localized: "cockpit.nav.loadingProjects", defaultValue: "Reading plans…")
                             : String(localized: "cockpit.nav.noPlans", defaultValue: "No project has a plan yet."))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    ForEach(projects.summaries) { summary in
                        row(.project(path: summary.path), icon: "folder",
                            subtitle: projectSubtitle(summary))
                    }
                    row(.portfolio, icon: "point.3.filled.connected.trianglepath.dotted")
                    Button { ResearchVaultWindowController.shared.show(query: "") } label: {
                        rowLabel(title: String(localized: "Research Vault"), icon: "books.vertical",
                                 subtitle: nil, badge: nil, isOn: false)
                    }
                    .buttonStyle(.plain)

                    sectionHeader("cockpit.nav.work", "Work")
                    row(.sessions, icon: "terminal", subtitle: sessionsHint)
                    row(.usage, icon: "chart.bar", subtitle: cockpit.binding.map { "\($0.pct) %" })
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
            Divider()
            settingsFooter
            Divider()
            machineFooter
        }
        .frame(width: 224)
        .background(.bar)
        .task(id: cockpit.sessions.map(\.cwd)) { await projects.refresh() }
    }

    // MARK: Rows

    private func row(_ destination: CockpitDestination, icon: String, subtitle: String? = nil,
                     badge: String? = nil) -> some View {
        let isOn = cockpit.destination == destination
        return Button { cockpit.destination = destination } label: {
            rowLabel(title: destination.title, icon: icon, subtitle: subtitle, badge: badge, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func rowLabel(title: String, icon: String, subtitle: String?, badge: String?, isOn: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(isOn ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13, weight: isOn ? .semibold : .regular)).lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge {
                Text(verbatim: badge).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isOn ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ key: StaticString, _ fallback: String.LocalizationValue) -> some View {
        Text(String(localized: key, defaultValue: fallback))
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// The settings that used to crowd the top bar, each saying its current value
    /// and opening the place where it changes.
    private var settingsFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingRow(String(localized: "Model"), value: cockpit.routingMode.label, icon: "arrow.triangle.branch") {
                AIRoutingWindowController.shared.show()
            }
            settingRow(String(localized: "Answers"), value: Self.styleName(OutputStyleManager.activeName()),
                       icon: "text.alignleft") {
                OutputStyleWindowController.shared.show()
            }
            settingRow(String(localized: "Exact quota"),
                       value: appState.exactSnapshot != nil ? String(localized: "connected")
                                                           : String(localized: "not connected"),
                       icon: "scope") {
                cockpit.destination = .usage
            }
            settingRow(String(localized: "Plan"),
                       value: appState.isPro ? "Pro" : String(localized: "Free"), icon: "person.crop.circle") {
                if !appState.isPro, let url = URL(string: "https://lorislab.fr/throttle/buy") {
                    NSWorkspace.shared.open(url)
                }
            }
            settingRow(String(localized: "Portfolio setup"), value: nil, icon: "square.stack.3d.up") {
                GlobalRAGOnboardingWindowController.shared.show(canInstallMCP: appState.isPro) { _ in }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func settingRow(_ title: String, value: String?, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(verbatim: title).font(.system(size: 12))
                Spacer(minLength: 4)
                if let value {
                    Text(verbatim: value).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: value.map { "\(title), \($0)" } ?? title))
    }

    static func styleName(_ name: String) -> String {
        name == "Default" ? String(localized: "Default") : name.replacingOccurrences(of: "Throttle ", with: "")
    }

    private var machineFooter: some View {
        let machine = cockpit.machine
        return VStack(alignment: .leading, spacing: 2) {
            let used = Self.gigabytes(machine.usedBytes), total = Self.gigabytes(machine.totalBytes)
            Text(String(localized: "Memory \(used) of \(total)"))
                .font(.system(size: 11)).foregroundStyle(machine.underPressure ? Color.orange : .secondary)
            if let scan = projects.lastScan {
                Text(String(localized: "Plans read \(scan.formatted(.relative(presentation: .named)))"))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Wording

    /// Waiting sessions plus decisions nobody settled, across every project.
    private var todayCount: Int {
        cockpit.waitingCount + projects.summaries.reduce(0) { $0 + $1.openDecisions.count }
    }

    private var sessionsHint: String {
        let live = cockpit.sessions.filter(\.isLive).count
        let asleep = cockpit.sessions.count - live
        return String(localized: "\(live) active · \(asleep) asleep")
    }

    /// The plan state, then how many sessions work in the project.
    private func projectSubtitle(_ summary: CockpitProjectsModel.Summary) -> String {
        let count = projects.sessions(in: summary.path, from: cockpit).count
        let hint = Self.projectHint(summary) ?? ""
        guard count > 0 else { return hint }
        return hint + " · " + String(localized: "\(count) session(s)")
    }

    static func projectHint(_ summary: CockpitProjectsModel.Summary) -> String? {
        let decisions = summary.openDecisions.count
        if decisions > 0 {
            return String(localized: "\(decisions) decision(s) waiting")
        }
        if summary.blockedCount > 0 {
            return String(localized: "\(summary.blockedCount) blocked or failed")
        }
        guard let progress = summary.overview?.progress else {
            return String(localized: "No plan yet")
        }
        return String(localized: "\(progress.proven)/\(progress.total) verified")
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f Go", Double(bytes) / 1_073_741_824)
    }
}
