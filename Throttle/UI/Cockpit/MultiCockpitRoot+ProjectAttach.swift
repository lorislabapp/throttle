import AppKit
import SwiftUI

extension MultiCockpitRoot {
    /// Right-click on a session: open the project it belongs to, attach it to a
    /// different one when the automatic guess is wrong, or undo that choice.
    @ViewBuilder func projectMenu(_ session: CockpitTab) -> some View {
        let projects = CockpitProjectsModel.shared
        let root = projects.rootByWorkingDirectory[session.cwd]
            ?? SessionProjectResolver.projectRoot(forWorkingDirectory: session.cwd)
        if let root {
            Button {
                model.destination = .project(path: root)
            } label: {
                Label(String(localized: "Open project \(URL(fileURLWithPath: root).lastPathComponent)"),
                      systemImage: "folder")
            }
        }
        Button { attachToProject(session) } label: {
            Label(String(localized: "Attach to a project…"), systemImage: "folder.badge.plus")
        }
        if SessionProjectResolver.storedOverrides()[URL(fileURLWithPath: session.cwd).standardizedFileURL.path] != nil {
            Button(String(localized: "Detach from project (back to automatic)")) {
                SessionProjectResolver.setOverride(cwd: session.cwd, projectRoot: nil)
                Task { await projects.refresh() }
            }
        }
    }

    private func attachToProject(_ session: CockpitTab) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the project folder for this session")
        panel.prompt = String(localized: "Attach")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: session.cwd)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SessionProjectResolver.setOverride(cwd: session.cwd, projectRoot: url.path)
        Task {
            await CockpitProjectsModel.shared.refresh()
            model.destination = .project(path: url.standardizedFileURL.path)
        }
    }
}
