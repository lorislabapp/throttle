import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    @ViewBuilder
    var menuBarSettings: some View {
        SettingsGroupHeader(label: "Menu bar")
        SettingsRow(title: "Cap pressure",
                    sub: "The percentage, or the reset countdown once a window is full. Always shown — it is the warning Throttle exists to give.") {
            Text("Always on").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(MenuBarSignal.renderOrder) { signal in
            SettingsHair()
            SettingsRow(title: signal.title, sub: signal.detail) {
                Toggle("", isOn: Binding(
                    get: { menuBarSignals.isOn(signal) },
                    set: { menuBarSignals.set(signal, on: $0) }
                ))
                .labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
        }
    }
}
