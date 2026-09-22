import AppKit
import SwiftUI

/// Chat-style Assistant tab inside the Project window. Streams responses
/// from whichever AIProvider is active (Apple Intelligence by default on
/// macOS 26+, otherwise Claude API key when configured). Keeps the
/// transcript ephemeral — there's no persistence in v2.x; closing the
/// window clears the conversation. Persistence lands in v2.x.x once
/// users tell us they want it.
struct ProjectAssistantTab: View {
    @Environment(AppState.self) var appState
    let project: ProjectInfo

    /// An isolated host can exercise this view without probing credentials,
    /// model installations or project files. Normal windows use the live path.
    struct RuntimeOverride {
        let provider: any AIProvider
        let context: @MainActor (ProjectInfo) async -> ProjectChatContext
    }
    var runtimeOverride: RuntimeOverride?

    init(project: ProjectInfo, runtimeOverride: RuntimeOverride? = nil) {
        self.project = project
        self.runtimeOverride = runtimeOverride
    }

    @State var transcript: [ChatMessage] = []
    @State var input: String = ""
    @State var isStreaming = false
    @State var sendTask: Task<Void, Never>?
    @State var sendGeneration: UUID?
    @State var streamingMessageID: UUID?
    @State var providerStatus: ProviderStatus = .resolving
    @State private var contextLoading: Bool = false
    @State var loadedContext: ProjectChatContext?
    @State var contextGeneration = UUID()
    @State var forceShowOnboarding: Bool = false
    @State var applyContext: ApplyContext?
    /// Click-able follow-up prompts shown below the latest assistant
    /// summary bubble (set after the user accepts/skips patches via the
    /// Apply sheet). Cleared when the user picks one or sends any new
    /// message of their own.
    @State var followUpSuggestions: [String] = []
    @State private var embeddedModelInstalled = false
    @State private var embeddedModelInstalling = false
    @State private var embeddedModelProgress = 0.0
    @State private var embeddedModelError = ""

    /// Per-entry expansion state for the inline tool-result cards. Keyed
    /// by `<msg.id>-<entryIdx>` so each row in a batch tool_result can
    /// expand independently.
    @State var expandedToolResults: Set<String> = []

    /// Cockpit fills — subtle graphite, matching the rest of the app.
    let hair = Color.primary.opacity(0.09)
    let chipBG = Color.primary.opacity(0.05)

    /// `.sheet(item:)` pattern — bundling the patches with an Identifiable
    /// wrapper guarantees the sheet's content closure receives a fresh
    /// snapshot, sidestepping the SwiftUI timing issue where setting two
    /// `@State`s in the same action could leave `.sheet(isPresented:)`'s
    /// content reading the old `pendingPatches` value.
    struct ApplyContext: Identifiable {
        let id = UUID()
        let patches: [AssistantPatch]
    }

    enum ProviderStatus: Equatable {
        case resolving
        case ready(name: String)
        case unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Rectangle().fill(hair).frame(height: 1)
            if showOnboarding {
                onboardingWizard
            } else {
                transcriptScroll
                Rectangle().fill(hair).frame(height: 1)
                inputBar
            }
        }
        .task {
            if runtimeOverride == nil { embeddedModelInstalled = EmbeddedModelRuntime.isInstalled }
            await refreshProvider()
        }
        .onDisappear { stopResponse() }
        .onChange(of: project.id) { _, _ in
            stopResponse()
            transcript.removeAll()
            loadedContext = nil
            contextGeneration = UUID()
            Task { await refreshProvider() }
        }
        .sheet(item: $applyContext) { ctx in
            ApplyPatchesSheet(
                patches: ctx.patches,
                onClose: { applyContext = nil },
                onCompleted: { applied, skipped in
                    appendApplySummary(applied: applied, skipped: skipped, total: ctx.patches.count)
                }
            )
        }
    }

}

extension ProjectAssistantTab {
    /// Shows the picker the first time the Assistant tab is opened, OR
    /// any time the user manually re-opens it via the status-bar button,
    /// OR when no provider is available. Persisted via UserDefaults so
    /// the choice sticks across launches but the user can revisit.
    private var showOnboarding: Bool {
        if runtimeOverride != nil { return false }
        if forceShowOnboarding { return true }
        if case .unavailable = providerStatus { return true }
        if !UserDefaults.standard.bool(forKey: "assistantOnboardingDone") {
            return true
        }
        return false
    }

    /// First-run wizard: shown the first time the user opens the Assistant
    /// tab without any provider configured. Picks one of three paths and
    /// writes the choice to AIProviderRegistry. We refresh the provider
    /// state immediately after so the wizard collapses into the chat UI.
    private var onboardingWizard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick how the Assistant talks to AI")
                        .font(.title2.bold())
                    Text("""
                        Choose where the Assistant processes your context. \
                        You can change this later in the chat header.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                qualityPicker
                    .padding(.bottom, 8)

                providerCard(
                    kind: .appleIntelligence,
                    title: String(localized: "Apple Intelligence"),
                    badge: String(localized: "Free · local · private"),
                    description: String(localized: "Runs on your Mac (macOS 26+ with Apple Intelligence enabled). Nothing leaves your device. Quality is OK for short questions; longer audits are better with Claude."),
                    requiresExtra: false
                )

                providerCard(
                    kind: .embeddedModel,
                    title: String(localized: "Qwen embedded"),
                    badge: String(localized: "Free · local · no Ollama"),
                    description: embeddedModelInstalled
                        ? String(localized: "Qwen 3 1.7B runs directly inside Throttle through MLX. Project context never leaves this Mac and there is no cloud fallback.")
                        : String(localized: "Installs the 968 MB Qwen 3 1.7B 4-bit model once, then runs fully offline inside Throttle. No Ollama daemon or account required."),
                    requiresExtra: false,
                    actionTitle: embeddedModelInstalled
                        ? String(localized: "Use this")
                        : (embeddedModelInstalling
                           ? String(localized: "Installing \(Int(embeddedModelProgress * 100))%")
                           : String(localized: "Install & use")),
                    disabled: embeddedModelInstalling
                )
                if !embeddedModelError.isEmpty {
                    Text(embeddedModelError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ModelCardLink(title: "Model card · Apache 2.0", url: EmbeddedModelRuntime.modelURL)
                    .font(.caption)

                providerCard(
                    kind: .selfHostedModel,
                    title: String(localized: "Your Ollama server"),
                    badge: String(localized: "Network · explicitly selected"),
                    description: String(localized: """
                        Sends your Assistant messages and project context to the server configured \
                        in Settings → Assistant. This is network processing, separate from Qwen on this Mac. \
                        No embedded model download is required.
                        """),
                    requiresExtra: false
                )

                providerCard(
                    kind: .claudeWebSession,
                    title: String(localized: "Claude (your subscription)"),
                    badge: String(localized: "Free for you · uses your Claude Pro/Max plan"),
                    description: String(localized: "Sign in to claude.ai inside Throttle (one-time, per Mac). No Safari needed — Throttle has its own session. Each chat counts against your existing Claude subscription quota. Auto-detects your plan tier (Pro / Max 5x / Max 20x) so the meter calibration is right out of the box."),
                    requiresExtra: false
                )

                providerCard(
                    kind: .claudeAPIKey,
                    title: String(localized: "Claude API key (your key)"),
                    badge: String(localized: "Best quality · billed by Anthropic on your key"),
                    description: String(localized: """
                        Paste an Anthropic API key. Stored in macOS Keychain. Anthropic bills usage separately \
                        according to the selected model and tokens processed.
                        """),
                    requiresExtra: true
                )
            }
            .padding(20)
        }
    }

    /// Quality vs speed/cost preference. Default is `.maxAccuracy`
    /// because the assistant is primarily an audit tool — wrong answers
    /// are worse than slow ones. Power users on a tight latency or
    /// per-call-cost budget can opt down.
    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer quality")
                .font(.subheadline.bold())
            Text("""
                Affects the API-key provider only. Embedded Qwen, Apple Intelligence, the selected server, \
                and Claude subscription manage their own model.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: Binding(
                get: { AIProviderRegistry.shared.qualityPreference },
                set: { AIProviderRegistry.shared.qualityPreference = $0 }
            )) {
                Text("Max accuracy").tag(AIQualityPreference.maxAccuracy)
                Text("Balanced").tag(AIQualityPreference.balanced)
                Text("Speed").tag(AIQualityPreference.speed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Refined prompts", selection: Binding(
                get: { RefinerSettings.output },
                set: { RefinerSettings.output = $0 }
            )) {
                ForEach(RefinerOutput.allCases) { Text($0.label).tag($0) }
            }
            .help("What the cockpit refiner's apply button does. Insert never presses Return.")

            Picker("Explain changes", selection: Binding(
                get: { RefinerSettings.rationale },
                set: { RefinerSettings.rationale = $0 }
            )) {
                ForEach(RefinerRationale.allCases) { Text($0.label).tag($0) }
            }
            .help("When the refiner shows why it rewrote your draft.")

            Toggle("Refine with a local model only", isOn: Binding(
                get: { RefinerSettings.forceLocal },
                set: { RefinerSettings.forceLocal = $0 }
            ))
            .help(
                "Keeps refinements on Apple Intelligence or the embedded model, "
                    + "so optimising tokens never costs tokens."
            )
        }
        .padding(12)
        .background(chipBG, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func providerCard(
        kind: AIProviderKind,
        title: String,
        badge: String,
        description: String,
        requiresExtra: Bool,
        actionTitle: String? = nil,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(chipBG, in: Capsule())
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    if kind == .embeddedModel && !embeddedModelInstalled {
                        installEmbeddedModel()
                    } else {
                        pickProvider(kind, requiresExtra: requiresExtra)
                    }
                } label: {
                    Text(actionTitle ?? (requiresExtra
                         ? String(localized: "Set up")
                         : String(localized: "Use this")))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(disabled)
            }
        }
        .padding(14)
        .background(chipBG, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hair, lineWidth: 1))
    }

    private func pickProvider(_ kind: AIProviderKind, requiresExtra: Bool) {
        AIProviderRegistry.shared.preferredKind = kind
        UserDefaults.standard.set(true, forKey: "assistantOnboardingDone")
        forceShowOnboarding = false
        if requiresExtra && kind == .claudeAPIKey {
            // Pop the meter dropdown's General settings so the user can
            // paste their key. The Project window stays open behind it.
            if let url = URL(string: "throttle://settings/ai") {
                NSWorkspace.openInBackground(url)
            }
        }
        Task { await refreshProvider() }
    }

    private func installEmbeddedModel() {
        embeddedModelInstalling = true
        embeddedModelError = ""
        Task {
            do {
                try await EmbeddedModelRuntime.shared.install { fraction in
                    embeddedModelProgress = fraction
                }
                embeddedModelInstalled = true
                embeddedModelInstalling = false
                pickProvider(.embeddedModel, requiresExtra: false)
            } catch {
                embeddedModelInstalling = false
                embeddedModelError = error.localizedDescription
            }
        }
    }

}

/// Three pulsing dots shown while the assistant message hasn't started
/// streaming yet. Plain SwiftUI animation — no Canvas, no Metal.
struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 0.95 : 0.35)
            }
        }
        .frame(height: 18)
        .task { await tick() }
    }

    private func tick() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(280))
            await MainActor.run {
                phase = (phase + 1) % 3
            }
        }
    }
}
