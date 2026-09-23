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

extension MultiCockpitModel {
    /// Opens the session that launched a task, found by the mission it carries.
    /// False when no open tab owns it (closed, or launched elsewhere).
    @discardableResult
    func showSession(forMission missionID: String?) -> Bool {
        guard let missionID, let tab = sessions.first(where: { $0.missionID.uuidString == missionID }) else {
            return false
        }
        wake(tab.id)
        activeID = tab.id
        destination = .sessions
        viewMode = .rail
        return true
    }

    func hasSession(forMission missionID: String?) -> Bool {
        guard let missionID else { return false }
        return sessions.contains { $0.missionID.uuidString == missionID }
    }
}
