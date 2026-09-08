import AppKit
import SwiftUI

extension GlobalRAGOnboardingView {
    func advance() {
        switch step {
        case 1:
            step = 2
            scan()
        case 4:
            finish()
        default:
            if step == 3 { status = "" }
            step += 1
        }
    }

    func chooseRoots() {
        guard !AppDelegate.isIsolatedHost else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose project folders")
        panel.prompt = String(localized: "Add")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url.standardizedFileURL.path) {
            roots.append(url.standardizedFileURL.path)
        }
    }

    func scan() {
        guard !AppDelegate.isIsolatedHost else { return }
        guard !isScanning else { return }
        isScanning = true
        status = ""
        let selectedRoots = roots
        Task {
            let found = await Task.detached(priority: .utility) {
                GlobalRAGOnboardingService.scan(roots: selectedRoots)
            }.value
            projects = found
            selectedProjectID = found.first?.id
            status = String(localized: "Found \(found.count) repositories locally. Nothing was modified.")
            isScanning = false
        }
    }

    func suggestLocally(index: Int) {
        guard !AppDelegate.isIsolatedHost else { return }
        let project = projects[index]
        aiInFlight.insert(project.id)
        Task {
            do {
                let (proposal, backend) = try await GlobalRAGOnboardingService.localProposal(for: project)
                guard let current = projects.firstIndex(where: { $0.id == project.id }) else { return }
                GlobalRAGOnboardingService.apply(proposal, to: &projects[current], backend: backend)
            } catch {
                guard let current = projects.firstIndex(where: { $0.id == project.id }) else { return }
                projects[current].localAINote = error.localizedDescription
                projects[current].localAIBackend = String(localized: "Rejected local result")
            }
            aiInFlight.remove(project.id)
        }
    }

    func finish() {
        guard !AppDelegate.isIsolatedHost else { return }
        let profile = GlobalRAGOnboardingService.profile(roots: roots, projects: projects)
        let shouldManageMCP = canInstallMCP
        let desiredMCPState = installMCP
        isSaving = true
        Task {
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try GlobalRAGService.saveProfile(profile)
                    _ = GlobalRAGService.buildSnapshot(profile: profile)
                    if shouldManageMCP {
                        if desiredMCPState {
                            _ = try TranscriptMemoryInstaller.install()
                        } else if TranscriptMemoryInstaller.isInstalled() {
                            try TranscriptMemoryInstaller.remove()
                        }
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            isSaving = false
            if let failure {
                status = String(localized: "Could not finish setup: \(failure)")
            } else {
                UserDefaults.standard.set(true, forKey: GlobalRAGOnboardingService.completedKey)
                let message = shouldManageMCP && desiredMCPState
                    ? String(
                        localized: """
                        Global RAG configured for \(profile.projects.count) projects. \
                        Restart Claude Code and Codex.
                        """
                    )
                    : String(localized: "Global RAG profile created for \(profile.projects.count) projects.")
                onComplete(message)
                close()
            }
        }
    }

    func close() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

}
