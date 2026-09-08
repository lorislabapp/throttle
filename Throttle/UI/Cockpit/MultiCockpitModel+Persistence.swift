import AppKit
import SwiftTerm
import SwiftUI

extension MultiCockpitModel {
    struct Saved: Codable {
        let cwd: String
        let name: String
        let sessionId: String?
        let runtime: AgentRuntime?
        let missionID: UUID?
        let isHibernated: Bool?
        let offloadedRemoteID: String?
    }

    func persist() {
        guard !isQuitting else { return }
        // NEVER overwrite the saved working set with an empty list we never loaded
        // (e.g. the app launched but the cockpit was never opened, so restore()
        // didn't run). That would wipe the user's sessions on quit.
        guard sessionsLoaded else { return }
        let saved = sessions.map {
            Saved(cwd: $0.cwd, name: $0.projectName, sessionId: $0.sessionId,
                  runtime: $0.runtime, missionID: $0.missionID, isHibernated: $0.isHibernated,
                  offloadedRemoteID: $0.offloadedRemoteID)
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    func restore() {
        let saved = UserDefaults.standard.data(forKey: Self.persistKey)
            .flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        let fm = FileManager.default
        for item in saved {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.cwd, isDirectory: &isDir), isDir.boolValue else { continue }
            let tab = CockpitTab(
                projectName: item.name,
                cwd: item.cwd,
                runtime: item.runtime ?? .claudeCode,
                missionID: item.missionID ?? UUID(),
                resumeSessionId: item.sessionId
            )
            tab.isHibernated = item.isHibernated ?? false
            tab.offloadedRemoteID = item.offloadedRemoteID
            tab.restoreRemoteOwnership()
            tab.requiresNativePicker = tab.runtime.usesTranscript && item.sessionId == nil
            wire(tab)
            sessions.append(tab)
        }
        restoreTransferTabs()
        recomputeSortOrder()
        activeID = sessions.first?.id   // spawns ONLY the active tab (others dormant)
    }
}
