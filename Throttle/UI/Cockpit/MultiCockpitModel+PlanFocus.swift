import Foundation

extension MultiCockpitModel {
    /// The session whose working directory is exactly this project root, preferring
    /// a live one. The Plan view reads the active session's directory as the
    /// project, so only an exact match shows the right plan.
    func session(atProjectRoot root: URL) -> CockpitTab? {
        let target = root.standardizedFileURL.path
        let matches = sessions.filter { URL(fileURLWithPath: $0.cwd).standardizedFileURL.path == target }
        return matches.first { !$0.isHibernated } ?? matches.first
    }

    /// Opens the project's page on its plan, with the task selected. The page
    /// binds to the project folder itself, so no session needs to be open.
    @discardableResult
    func focusPlan(projectRoot: URL, taskID: String) -> Bool {
        pendingPlanSelection = taskID
        destination = .project(path: projectRoot.standardizedFileURL.path)
        return true
    }
}
