import SwiftUI

extension ProjectOptimizerTab {
    // MARK: - Actions

    /// Existence-gated URL (nil when the file is absent).
    func url(for file: EditableFile) -> URL? {
        switch file {
        case .claudeMd:          return project.claudeMdURL
        case .settingsJSON:      return project.settingsJSONURL
        case .settingsLocalJSON: return project.settingsLocalJSONURL
        }
    }

    /// The target path REGARDLESS of existence — so we can create the file.
    func targetURL(for file: EditableFile) -> URL? {
        guard let root = project.url else { return nil }
        switch file {
        case .claudeMd:          return root.appendingPathComponent("CLAUDE.md")
        case .settingsJSON:      return root.appendingPathComponent(".claude/settings.json")
        case .settingsLocalJSON: return root.appendingPathComponent(".claude/settings.local.json")
        }
    }

    func fileExists(for file: EditableFile) -> Bool {
        guard let fileURL = targetURL(for: file) else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func reload() {
        cancelOptimization()
        lastBackupURL = nil
        loading = true
        status = ""
        rationale = []
        diffMode = false
        let text: String
        if let fileURL = targetURL(for: selectedFile), FileManager.default.fileExists(atPath: fileURL.path) {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        } else {
            text = ""   // file absent — AI can generate a starter
        }
        originalContents = text
        proposedContents = text
        loading = false
    }

    func cancelOptimization() {
        revision = UUID()
        optimizationTask?.cancel()
        optimizationTask = nil
        optimizing = false
    }

    func startOptimization() {
        guard !optimizing else { return }
        optimizationTask = Task { await optimizeWithAI() }
    }

    /// Empty file → an honest static starter (the AI can't know this project's
    /// specifics, so asking it invents fake paths/models). Existing file → AI.
    func optimizeWithAI() async {
        let requestRevision = revision
        if originalContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proposedContents = starterTemplate(for: selectedFile)
            rationale = ["New starter — a generic scaffold; fill in the placeholders for this project.",
                         "Grounds Claude Code in your conventions from the first session, kept short."]
            diffMode = true
            status = ""
            return
        }
        optimizing = true; status = ""; rationale = []
        do {
            guard selectedFile == .claudeMd else {
                throw AIOptimizerService.OptimizerError.settingsUseLocalChecks
            }
            let provider = await AIProviderRegistry.shared.resolveOnDevice()
            guard revision == requestRevision, !Task.isCancelled else { return }
            guard let provider else { throw AIOptimizerService.OptimizerError.localModelRequired }
            let proposal = try await AIOptimizerService.optimize(
                fileLabel: selectedFile.rawValue, content: originalContents,
                projectName: project.displayName, projectPath: project.projectPath, provider: provider)
            await MainActor.run {
                guard revision == requestRevision, !Task.isCancelled else { return }
                proposedContents = proposal.proposed
                rationale = proposal.why
                diffMode = proposal.changed   // show the diff when there's something to see
                if !proposal.changed {
                    status = String(localized: "No changes proposed (via \(proposal.provider)).")
                } else {
                    status = String(localized: "Proposed via \(proposal.provider).")
                }
                optimizing = false
            }
        } catch {
            await MainActor.run {
                guard revision == requestRevision, !Task.isCancelled else { return }
                status = String(localized: "Optimize failed: \(error.localizedDescription)")
                optimizing = false
            }
        }
    }

    /// Deterministic settings hardening — no AI provider needed. Merges the
    /// suggested deny rules and shows the diff, preserving model/effort choices,
    /// reusing the existing Apply (backup + atomic) pipeline. Works on an absent
    /// file too (creates a hardened settings.json from nothing).
    func quickWins() {
        guard selectedFile != .claudeMd else { return }
        let auditResult = SettingsAuditService.audit(currentJSON: originalContents)
        proposedContents = auditResult.proposed
        rationale = auditResult.why
        diffMode = auditResult.changed
        status = auditResult.changed ? "" : String(localized: "No settings changes proposed.")
    }

    /// Honest, generic starter — no invented project specifics (placeholders the
    /// user fills in). Far better than a weak model hallucinating /tmp paths.
    func starterTemplate(for file: EditableFile) -> String {
        switch file {
        case .claudeMd:
            let detected = project.url.flatMap { detectStack(at: $0) }
            let stack = detected?.stack ?? "<!-- e.g. Swift 6 / SwiftUI · Node + TypeScript · Python -->"
            let build = detected?.build ?? "<!-- e.g. xcodebuild -scheme … / npm run build -->"
            let test  = detected?.test ?? "<!-- e.g. swift test / npm test -->"
            return """
            # \(project.displayName)

            Project context for Claude Code. Keep this tight — it's re-sent every session.

            ## Stack
            \(stack)

            ## Conventions
            - <!-- coding style, naming, file layout -->

            ## Commands
            - Build: \(build)
            - Test:  \(test)

            ## Don't
            - <!-- things to avoid in this repo -->
            """
        case .settingsJSON, .settingsLocalJSON:
            return "{\n}\n"
        }
    }

    /// Detect the project's real stack from disk (honest — never invented).
    /// Fills Stack + Commands with actual build/test commands.
    struct DetectedStack {
        let stack: String
        let build: String
        let test: String
    }

    func detectStack(at root: URL) -> DetectedStack? {
        let manager = FileManager.default
        func has(_ path: String) -> Bool { manager.fileExists(atPath: root.appendingPathComponent(path).path) }
        let contents = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []

        if has("Package.swift") {
            return DetectedStack(stack: "Swift · SwiftPM", build: "swift build", test: "swift test")
        }
        if let xcodeProject = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            let scheme = (xcodeProject as NSString).deletingPathExtension
            return DetectedStack(stack: "Swift · Xcode", build: "xcodebuild -scheme \(scheme) build",
                                 test: "xcodebuild -scheme \(scheme) test")
        }
        if has("package.json") {
            return DetectedStack(stack: has("tsconfig.json") ? "Node · TypeScript" : "Node · JavaScript",
                                 build: "npm run build", test: "npm test")
        }
        if has("Cargo.toml") { return DetectedStack(stack: "Rust · Cargo", build: "cargo build", test: "cargo test") }
        if has("go.mod") { return DetectedStack(stack: "Go", build: "go build ./...", test: "go test ./...") }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
            return DetectedStack(stack: "Python", build: "<!-- install deps -->", test: "pytest")
        }
        return nil
    }

    func apply() async {
        guard let url = targetURL(for: selectedFile) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let result = try await FileEditor.shared.write(url, contents: proposedContents)
            await MainActor.run {
                status = String(localized: "Saved at \(formatTime(result.timestamp)) · backup beside the file")
                lastBackupURL = result.backupURL
                originalContents = proposedContents
            }
        } catch {
            await MainActor.run {
                status = String(localized: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    func rollback(to backup: URL) {
        guard let url = url(for: selectedFile) else { return }
        Task {
            do {
                try await FileEditor.shared.rollback(backup, to: url)
                await MainActor.run {
                    status = String(localized: "Rolled back from \(backup.lastPathComponent)")
                    lastBackupURL = nil
                    reload()
                }
            } catch {
                await MainActor.run {
                    status = String(localized: "Rollback failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
