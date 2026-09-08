import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    // MARK: B — Project rail

    var railLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    gLabel(model.activityFilter == .all
                           ? "SESSIONS · \(model.sessions.count)"
                           : "SESSIONS · \(model.visibleSessions.count)/\(model.sessions.count)")
                    Spacer()
                    if model.waitingCount > 0 { waitingChip(model.waitingCount) }
                    activityFilterMenu
                    sortMenu
                }.padding(.horizontal, 13).padding(.vertical, 9)
                if let issue = model.transferRecoveryIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange).padding(8)
                }
                if model.transferRecoveryCount > 0, model.activityFilter != .all {
                    Button("Show saved transfers") { model.activityFilter = .all }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(8)
                }
                // Search only appears once the rail is crowded — no permanent chrome
                // for the common few-session case.
                if model.sessions.count > 6 { railSearchField }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredSessions) { s in railRow(s) }
                        if filteredSessions.isEmpty, !railFilter.isEmpty {
                            Text("No session matches “\(railFilter)”.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.vertical, 12)
                        } else if filteredSessions.isEmpty, model.activityFilter != .all, !model.sessions.isEmpty {
                            activityFilterEmptyState
                        }
                        // Edge-agent sessions live on the user's box, not this Mac.
                        // A remote OWNED by a local tab (offloaded from it) is NOT
                        // listed here — its local row wears the REMOTE badge
                        // instead, so one session never shows as two rows. Only
                        // orphan remotes (started from the sheet / another device)
                        // appear in this section.
                        if remoteSvc.isConfigured,
                           !orphanRemotes.isEmpty || remoteSvc.offloadStatus != nil {
                            HStack {
                                gLabel("REMOTE · \(orphanRemotes.count)")
                                Spacer()
                            }.padding(.horizontal, 5).padding(.top, 10).padding(.bottom, 2)
                            if let st = remoteSvc.offloadStatus {
                                Text(st).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(orphanRemotes) { rs in remoteRailRow(rs) }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                Rectangle().fill(hair).frame(height: 1)
                newSessionMenu(gated: model.gated) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        Text("New session").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
                }.menuStyle(.borderlessButton)
            }
            .frame(width: 234)
            .overlay(alignment: .trailing) { Rectangle().fill(hair).frame(width: 1) }
            terminal
        }
    }

    /// Sort the session rail (last activity, cost, memory, name, waiting-first,
    /// or manual drag order). Drag-reorder stays available in Manual mode.
    var sortMenu: some View {
        Menu {
            ForEach(MultiCockpitModel.SortMode.allCases) { mode in
                Button {
                    model.sortMode = mode
                } label: {
                    if model.sortMode == mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String.localizedStringWithFormat(String(localized: "Sort sessions: %@"), model.sortMode.label))
        .accessibilityLabel(String(localized: "Sort sessions")).accessibilityValue(model.sortMode.label)
    }

    /// Sessions after the activity filter, then the rail text filter —
    /// case-insensitive substring on project name.
    var filteredSessions: [CockpitTab] {
        let q = railFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.visibleSessions }
        return model.visibleSessions.filter { $0.projectName.lowercased().contains(q) }
    }

    /// All / Live / Active. Shared by the rail and the tab bar; the counts let
    /// the two tiers be told apart before picking one. Reads only the model's
    /// stored counts — never a per-tab `state` (that would invalidate the whole
    /// cockpit on every PTY chunk).
    var activityFilterMenu: some View {
        let filtered = model.activityFilter != .all
        return Menu {
            ForEach(MultiCockpitModel.ActivityFilter.allCases) { tier in
                Button {
                    model.activityFilter = tier
                } label: {
                    let title = "\(tier.label) · \(activityTierCount(tier))"
                    if model.activityFilter == tier { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(filtered ? Color.accentColor : Color.secondary.opacity(0.6))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String.localizedStringWithFormat(String(localized: "Show: %@"), model.activityFilter.label))
        .accessibilityLabel(String(localized: "Filter sessions by activity"))
        .accessibilityValue(model.activityFilter.label)
    }

    func activityTierCount(_ tier: MultiCockpitModel.ActivityFilter) -> Int {
        switch tier {
        case .all:    return model.sessions.count
        case .live:   return model.liveCount
        case .active: return model.activeCount
        }
    }

    /// A ternary between two string literals types as `String`, which picks
    /// `Text(_: String)` — the overload that does NOT localize. Resolve the
    /// catalog lookup here instead.
    var activityFilterEmptyMessage: String {
        model.activityFilter == .active
            ? String(localized: "No active session.")
            : String(localized: "No live session.")
    }

    var showAllButton: some View {
        Button { model.activityFilter = .all } label: {
            Text("Show all").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
        }.buttonStyle(.plain)
    }

    /// Rail: stacked, centred in the empty list.
    var activityFilterEmptyState: some View {
        VStack(spacing: 6) {
            Text(activityFilterEmptyMessage).font(.system(size: 11)).foregroundStyle(.tertiary)
            showAllButton
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
    }

    /// Tab bar: one line at row height, because the bar is horizontal and 40pt tall.
    var activityFilterEmptyTab: some View {
        HStack(spacing: 8) {
            Text(activityFilterEmptyMessage).font(.system(size: 12)).foregroundStyle(.tertiary)
            showAllButton
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
    }

    var railSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            TextField("Filter sessions", text: $railFilter)
                .textFieldStyle(.plain).font(.system(size: 12))
            if !railFilter.isEmpty {
                Button { railFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.bottom, 4)
    }
}
