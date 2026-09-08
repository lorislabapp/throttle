import AppKit
import Foundation

extension AppDelegate {
    func configureExactMode() -> ExactModeService {
        let exact = ExactModeService.shared
        exact.onSnapshot = { [weak self] snap in
            Task { @MainActor in
                self?.appState.exactSnapshot = snap
                self?.appState.exactModeError = nil
                // Learn which model the per-model weekly cap belongs to, so the
                // label and the offline estimate stop assuming Sonnet.
                ScopedCapModel.remember(snap.sevenDayScoped.scopedModel)
                self?.appState.anchorCalibration(from: snap)   // make the local estimate track server truth
                self?.appState.refreshStatusline()   // keep the terminal line in sync with exact
            }
        }
        exact.onError = { [weak self] err in
            Task { @MainActor in
                // Non-recoverable errors (notSignedIn) — drop the snapshot so the UI
                // falls back to local math instead of showing stale data.
                if err == .notSignedIn {
                    self?.appState.exactSnapshot = nil
                }
                self?.appState.exactModeError = err
            }
        }

        return exact
    }

    func notifyReadFirewallIfNeeded() {
        Task.detached(priority: .utility) {
            let candidates = ProjectsService.listProjects().compactMap { project
                -> (ProjectInfo, String, ReadFirewallScanner.Summary)? in
                guard let path = ProjectsService.decodePath(project.encodedName),
                      FileManager.default.fileExists(atPath: path) else { return nil }
                let summary = ReadFirewallScanner.scan(encodedName: project.encodedName)
                return summary.highWaste ? (project, path, summary) : nil
            }
            guard let candidate = candidates.first else { return }
            await MainActor.run {
                let key = "readFirewallToast.\(candidate.0.encodedName)"
                let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
                guard Date().timeIntervalSince(last) > 7 * 86_400 else { return }
                UserDefaults.standard.set(Date(), forKey: key)
                CockpitNotifier.shared.notifyReadFirewall(
                    project: candidate.0.displayName,
                    projectPath: candidate.1,
                    summary: candidate.2)
            }
        }

    }
}
