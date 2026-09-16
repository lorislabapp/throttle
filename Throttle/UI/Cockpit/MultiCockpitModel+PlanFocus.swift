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

    /// Opens the Plan view on one task of a project. Returns false when no
    /// session works in that project, rather than showing another project's plan.
    @discardableResult
    func focusPlan(projectRoot: URL, taskID: String) -> Bool {
        guard let tab = session(atProjectRoot: projectRoot) else { return false }
        pendingPlanSelection = taskID
        activeID = tab.id
        viewMode = .plan
        return true
    }
}
