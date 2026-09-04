import AppKit
import SwiftUI

struct GlobalRAGOnboardingView: View {
    let canInstallMCP: Bool
    let onRequestClose: (() -> Void)?
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var roots = GlobalRAGOnboardingService.suggestedRoots()
    @State private var projects: [GlobalRAGOnboardingProject] = []
    @State private var selectedProjectID: String?
    @State private var isScanning = false
    @State private var isSaving = false
    @State private var aiInFlight: Set<String> = []
    @State private var status = ""
    @State private var localAIStatus = String(localized: "Checking local models…")
    @State private var useLocalAI = true
    @State private var installMCP = TranscriptMemoryInstaller.isInstalled()

    init(
        canInstallMCP: Bool,
        onRequestClose: (() -> Void)? = nil,
        onComplete: @escaping (String) -> Void
    ) {
        self.canInstallMCP = canInstallMCP
        self.onRequestClose = onRequestClose
        self.onComplete = onComplete
    }

    private var titles: [String] {
        [
            String(localized: "Privacy"),
            String(localized: "Project folders"),
            String(localized: "Local scan"),
            String(localized: "Review"),
            String(localized: "Activate")
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case 0: privacyStep
                case 1: rootsStep
                case 2: scanStep
                case 3: reviewStep
                default: activationStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 860, minHeight: 590, idealHeight: 680)
        .accessibilityIdentifier("global-rag-onboarding")
        .interactiveDismissDisabled(isSaving)
        .task {
            if !canInstallMCP { installMCP = false }
            localAIStatus = await GlobalRAGOnboardingService.localAIStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Global portfolio setup").font(.title2.bold())
                    Text("Step \(step + 1) of \(titles.count) · \(titles[step])")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("LOCAL FIRST")
                    .font(.caption2.bold()).tracking(0.8)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.green.opacity(0.12), in: Capsule())
                    .foregroundStyle(.green)
            }
            ProgressView(value: Double(step + 1), total: Double(titles.count))
                .accessibilityLabel("Onboarding progress")
                .accessibilityValue("Step \(step + 1) of \(titles.count)")
        }
        .padding(22)
    }

    private var privacyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Your portfolio remains yours", systemImage: "lock.shield")
                    .font(.title3.bold())
                Text("Throttle scans only folders you choose. It stores a small derived index and a portable profile. It never uploads source code, credentials, transcripts, or the profile from this assistant.")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                onboardingCard(
                    title: String(localized: "Deterministic first"),
                    body: String(localized: "Repository markers, dependency manifests, scripts, and indexed evidence are detected without AI. Every item remains editable before saving."),
                    icon: "checkmark.seal"
                )
                onboardingCard(
                    title: String(localized: "Optional local suggestions"),
                    body: localAIStatus + String(localized: " AI output is labelled, bounded, and never treated as proof."),
                    icon: "sparkles"
                )
                Toggle("Use a local model to propose cleaner labels and handoffs", isOn: $useLocalAI)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("global-rag-use-local-ai")
                Text("No cloud fallback. If the model is unavailable or its JSON is invalid, Throttle keeps the deterministic result.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(26)
        }
    }

    private var rootsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the folders that contain your projects").font(.title3.bold())
            Text("Throttle searches at most three directory levels, ignores build caches and symlinks, and never changes a repository.")
                .foregroundStyle(.secondary)
            List {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(root).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { roots.removeAll { $0 == root } }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .accessibilityIdentifier("global-rag-roots")
            .overlay {
                if roots.isEmpty {
                    ContentUnavailableView("No folders selected", systemImage: "folder.badge.questionmark", description: Text("Add one or more project folders to continue."))
                }
            }
            HStack {
                Button("Add folders…", systemImage: "plus") { chooseRoots() }
                    .accessibilityIdentifier("global-rag-add-folders")
                Spacer()
                Text(roots.count == 1
                     ? String(localized: "1 root")
                     : String(localized: "\(roots.count) roots"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var scanStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected projects").font(.title3.bold())
                    Text("Select only projects that should be available as global context.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isScanning ? "Scanning…" : "Scan again", systemImage: "arrow.clockwise") { scan() }
                    .disabled(isScanning)
                    .accessibilityIdentifier("global-rag-scan")
            }
            if isScanning {
                ProgressView("Reading repository metadata locally…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List($projects) { $project in
                    Toggle(isOn: $project.isIncluded) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.displayName).fontWeight(.medium)
                            Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(projectMetricsSummary(project))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .accessibilityIdentifier("global-rag-project-selection")
                .overlay {
                    if projects.isEmpty {
                        ContentUnavailableView("No repositories detected", systemImage: "magnifyingglass", description: Text(status.isEmpty ? "Check the selected folders, then scan again." : status))
                    }
                }
            }
            if !status.isEmpty && !projects.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var reviewStep: some View {
        HStack(spacing: 0) {
            List(selection: $selectedProjectID) {
                ForEach(projects.filter(\.isIncluded)) { project in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.displayName).fontWeight(.medium)
                        if project.localAIBackend != nil {
                            Label("AI suggestion reviewed", systemImage: "sparkles")
                                .font(.caption2).foregroundStyle(.purple)
                        }
                    }
                    .tag(project.id)
                }
            }
            .frame(minWidth: 210, idealWidth: 240, maxWidth: 270)
            Divider()
            if let index = selectedProjectIndex {
                projectEditor(index: index)
            } else {
                ContentUnavailableView("Select a project", systemImage: "sidebar.left", description: Text("Review every label before activation."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedProjectID == nil { selectedProjectID = projects.first(where: \.isIncluded)?.id }
        }
    }

    private func projectEditor(index: Int) -> some View {
        let id = projects[index].id
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review profile").font(.title3.bold())
                        Text(projects[index].path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if useLocalAI {
                        Button(aiInFlight.contains(id) ? "Analysing locally…" : "Suggest locally", systemImage: "sparkles") {
                            suggestLocally(index: index)
                        }
                        .disabled(aiInFlight.contains(id))
                        .accessibilityIdentifier("global-rag-suggest-locally")
                    }
                }
                TextField("Display name", text: $projects[index].displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("global-rag-display-name")
                ProfileListEditor(title: String(localized: "Aliases"), values: $projects[index].aliases, hint: String(localized: "One item per line"))
                ProfileListEditor(title: String(localized: "Capabilities"), values: $projects[index].capabilities, hint: String(localized: "Reusable product or technical abilities"))
                ProfileListEditor(title: String(localized: "Tools / SDKs"), values: $projects[index].tools, hint: String(localized: "Only tools worth reusing"))
                ProfileListEditor(title: String(localized: "Workflows"), values: $projects[index].workflows, hint: String(localized: "Build, test, release, website…"))
                ProfileListEditor(title: String(localized: "Handoffs"), values: $projects[index].handoffs, hint: String(localized: "Example: after release, prepare the website page"))
                if let backend = projects[index].localAIBackend {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Suggested by \(backend) — verify before saving", systemImage: "exclamationmark.bubble")
                            .font(.caption.bold()).foregroundStyle(.purple)
                        if let note = projects[index].localAINote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(10).background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Ready to create the portable profile", systemImage: "checkmark.circle")
                    .font(.title3.bold())
                onboardingCard(
                    title: selectedProjectsTitle,
                    body: discoveryRootsBody,
                    icon: "square.stack.3d.up"
                )
                Toggle("Install the shared MCP tools for Claude Code and Codex", isOn: $installMCP)
                    .toggleStyle(.switch)
                    .disabled(!canInstallMCP)
                    .accessibilityIdentifier("global-rag-install-mcp")
                if !canInstallMCP {
                    Text("MCP installation requires the Pro feature. The profile can still be created and exported.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Installing MCP updates local agent configuration with backups. Restart both agents afterward. This does not publish or upload anything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(status.hasPrefix("Could not") ? .red : .secondary) }
            }
            .padding(26)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { close() }.disabled(isSaving)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("global-rag-cancel")
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
                    .disabled(isSaving || isScanning)
                    .accessibilityIdentifier("global-rag-back")
            }
            Button(step == titles.count - 1 ? (isSaving ? "Saving…" : "Finish") : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdvance || isSaving || isScanning)
            .accessibilityIdentifier(step == titles.count - 1 ? "global-rag-finish" : "global-rag-continue")
        }
        .padding(16)
    }

    private var selectedProjectIndex: Int? {
        guard let selectedProjectID else { return nil }
        return projects.firstIndex { $0.id == selectedProjectID && $0.isIncluded }
    }

    private var canAdvance: Bool {
        switch step {
        case 1: return !roots.isEmpty
        case 2: return projects.contains(where: \.isIncluded)
        case 3: return projects.filter(\.isIncluded).allSatisfy { !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        default: return true
        }
    }

    private func advance() {
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

    private func chooseRoots() {
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

    private func scan() {
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

    private func suggestLocally(index: Int) {
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

    private func finish() {
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
                        if desiredMCPState { _ = try TranscriptMemoryInstaller.install() }
                        else if TranscriptMemoryInstaller.isInstalled() { try TranscriptMemoryInstaller.remove() }
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
                    ? String(localized: "Global RAG configured for \(profile.projects.count) projects. Restart Claude Code and Codex.")
                    : String(localized: "Global RAG profile created for \(profile.projects.count) projects.")
                onComplete(message)
                close()
            }
        }
    }

    private func close() {
        if let onRequestClose {
            onRequestClose()
        } else {
            dismiss()
        }
    }

    private func onboardingCard(title: String, body: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func projectMetricsSummary(_ project: GlobalRAGOnboardingProject) -> String {
        let capabilities = project.capabilities.count == 1
            ? String(localized: "1 capability")
            : String(localized: "\(project.capabilities.count) capabilities")
        let tools = project.tools.count == 1
            ? String(localized: "1 tool")
            : String(localized: "\(project.tools.count) tools")
        let workflows = project.workflows.count == 1
            ? String(localized: "1 workflow")
            : String(localized: "\(project.workflows.count) workflows")
        return "\(capabilities) · \(tools) · \(workflows)"
    }

    private var selectedProjectsTitle: String {
        let count = projects.filter(\.isIncluded).count
        return count == 1
            ? String(localized: "1 selected project")
            : String(localized: "\(count) selected projects")
    }

    private var discoveryRootsBody: String {
        if roots.count == 1 {
            return String(localized: "1 discovery root. The saved profile can later be exported as JSON or YAML.")
        }
        return String(localized: "\(roots.count) discovery roots. The saved profile can later be exported as JSON or YAML.")
    }
}

private struct ProfileListEditor: View {
    let title: String
    @Binding var values: [String]
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
            TextEditor(text: Binding(
                get: { values.joined(separator: "\n") },
                set: { values = $0.components(separatedBy: .newlines) }
            ))
            .font(.system(.callout, design: .rounded))
            .frame(minHeight: 58, maxHeight: 90)
            .padding(5)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            .accessibilityLabel(title)
            .accessibilityHint(hint)
        }
    }
}
