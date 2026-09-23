import Foundation

extension ResearchVaultWorkbenchModel {

    /// The key a typed project name becomes: "Éclair" and "eclair" are one space.
    nonisolated static func spaceKey(for name: String) -> String? {
        ResearchVaultFolderSource.canonicalProjectKey(name)
    }

    /// Spaces used to appear only once research for that project already existed,
    /// so a new project had no place to put its first folder. Creating one is now
    /// explicit, and it is selected straight away so "Add folder" targets it.
    @discardableResult
    func createProjectSpace(named name: String) -> Bool {
        guard !isIsolatedHost, let key = Self.spaceKey(for: name) else { return false }
        let keys = Set(spaces.flatMap(\.projectKeys)).union([key])
        try? ResearchVaultSpaceStore.saveProjectKeys(keys)
        refreshSpaces()
        selectSpace("project:" + key)
        status = String(localized: "Space \(key) created. Add the folder that holds its research.")
        return true
    }
}
