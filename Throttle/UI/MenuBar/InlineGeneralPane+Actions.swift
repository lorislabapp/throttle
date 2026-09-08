import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    /// Flag file the SessionStart hook reads to inject a terse-output directive
    /// into every Claude Code session. App writes it (non-sandboxed); hook reads it.
    static var conciseFlagPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-concise").path
    }
    func setConciseFlag(_ on: Bool) {
        conciseError = nil
        guard on else {
            try? FileManager.default.removeItem(atPath: Self.conciseFlagPath)
            try? BrevityHookService.remove()
            conciseClaudeCode = BrevityHookService.isInstalled()
            return
        }
        // The hooks are the reliable carrier: a one-line directive per prompt +
        // re-injection after compaction. The output style alone is read once at
        // session start, so it is invisible to open sessions and gone after the
        // first compaction — which is most of a long session.
        do {
            try BrevityHookService.install()
            FileManager.default.createFile(atPath: Self.conciseFlagPath, contents: Data())
        } catch {
            // Say so. The previous version swallowed this and wrote the flag
            // anyway, so the switch read "on" while nothing had been installed.
            conciseError = "Could not install the brevity hooks: \(error.localizedDescription)"
        }
        conciseClaudeCode = BrevityHookService.isInstalled()
        if conciseClaudeCode == false && conciseError == nil {
            conciseError = "The brevity hooks did not take. Check ~/.claude/settings.json."
        }
    }

    /// Save the generated team hardening policy as managed-settings.json.
    func exportTeamPolicy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "managed-settings.json"
        panel.message = "Deploy this to \(TeamPolicyService.deployPath) via MDM to enforce across a team."
        panel.prompt = "Export Policy"
        if panel.runModal() == .OK, let url = panel.url {
            try? TeamPolicyService.generate().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func importGlobalRAGProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import global portfolio RAG profile"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.json, UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try GlobalRAGService.importProfile(from: url)
            globalRAGNote = "Imported profile v\(profile.version): \(profile.projects.count) project rules, \(profile.roots.count) roots. Refresh occurs on next retrieval."
        } catch {
            globalRAGNote = "Import refused: \(error.localizedDescription)"
        }
    }

    func exportGlobalRAGProfile(_ format: GlobalRAGService.ProfileFormat) {
        let panel = NSSavePanel()
        let ext: String
        switch format {
        case .json: ext = "json"
        case .yaml: ext = "yaml"
        }
        panel.title = "Export global portfolio RAG profile"
        panel.nameFieldStringValue = "global-rag-profile.\(ext)"
        panel.prompt = "Export"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GlobalRAGService.exportProfile(to: url, format: format)
            globalRAGNote = "Exported a portable \(ext.uppercased()) profile. It contains configuration only, never indexed source text or credentials."
        } catch {
            globalRAGNote = "Export failed: \(error.localizedDescription)"
        }
    }

    var menuBarSignals: MenuBarSignalSettings { MenuBarSignalSettings.shared }
}
