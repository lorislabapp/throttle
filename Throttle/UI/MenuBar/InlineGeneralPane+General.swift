import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    @ViewBuilder
    var generalSettings: some View {
        SettingsGroupHeader(label: "General")
        SettingsRow(title: "Launch at login") {
            Toggle("", isOn: $loginItemsEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: loginItemsEnabled) { _, new in try? LoginItemService.setEnabled(new) }
        }
        SettingsHair()
        SettingsRow(title: "Keep Cockpit on top",
                    sub: "Float the Cockpit window above other apps — a companion you watch while working.") {
            Toggle("", isOn: $cockpitOnTop).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: cockpitOnTop) { _, new in CockpitWindowController.alwaysOnTop = new }
        }
        SettingsHair()
        SettingsRow(title: "Permission prompts",
                    sub: "Review agent permission requests in the terminal. "
                        + "Throttle never approves them automatically.") {
            Text("Manual").font(.caption).foregroundStyle(.secondary)
        }
        SettingsHair()
        SettingsRow(title: "Build for sessions on the box",
                    sub: "A session offloaded to the server has no Xcode. Let it ask this Mac to build, test or lint — a named capability, never a command.") {
            Toggle("", isOn: $hostCapabilities).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: hostCapabilities) { _, new in CapabilityHostService.shared.enabled = new }
        }
        SettingsHair()
        SettingsRow(title: "Notify at 80% and 95%",
                    sub: "A quiet banner as each window nears its cap.") {
            Toggle("", isOn: $notificationsOn).labelsHidden().toggleStyle(.switch).tint(.accentColor)
                .onChange(of: notificationsOn) { _, new in ThresholdNotifier.shared.setEnabled(new) }
        }
        SettingsHair()
        SettingsRow(title: "Weekly-reset reminder",
                    sub: calendarStatus.isEmpty ? "Add a Monday reset event to Calendar." : calendarStatus) {
            SettingsButton(title: "Add to Calendar", systemImage: "calendar") {
                Task {
                    let result = await CalendarReminderService.addNextWeeklyReset(
                        in: appState.snapshot, exact: appState.exactSnapshot)
                    await MainActor.run { handleCalendarResult(result) }
                }
            }
        }
    }
}
