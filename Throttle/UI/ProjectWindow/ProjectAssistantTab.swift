import AppKit
import SwiftUI

/// Chat-style Assistant tab inside the Project window. Streams responses
/// from whichever AIProvider is active (Apple Intelligence by default on
/// macOS 26+, otherwise Claude API key when configured). Keeps the
/// transcript ephemeral — there's no persistence in v2.x; closing the
/// window clears the conversation. Persistence lands in v2.x.x once
/// users tell us they want it.
struct ProjectAssistantTab: View {
    @Environment(AppState.self) private var appState
    let project: ProjectInfo

    @State private var transcript: [ChatMessage] = []
    @State private var input: String = ""
    @State private var isStreaming = false
    @State private var streamingMessageID: UUID?
    @State private var providerStatus: ProviderStatus = .resolving
    @State private var contextLoading: Bool = false
    @State private var loadedContext: ProjectChatContext?
    @State private var forceShowOnboarding: Bool = false
    @State private var applyContext: ApplyContext?
    /// Click-able follow-up prompts shown below the latest assistant
    /// summary bubble (set after the user accepts/skips patches via the
    /// Apply sheet). Cleared when the user picks one or sends any new
    /// message of their own.
    @State private var followUpSuggestions: [String] = []

    /// Per-entry expansion state for the inline tool-result cards. Keyed
    /// by `<msg.id>-<entryIdx>` so each row in a batch tool_result can
    /// expand independently.
    @State private var expandedToolResults: Set<String> = []

    /// `.sheet(item:)` pattern — bundling the patches with an Identifiable
    /// wrapper guarantees the sheet's content closure receives a fresh
    /// snapshot, sidestepping the SwiftUI timing issue where setting two
    /// `@State`s in the same action could leave `.sheet(isPresented:)`'s
    /// content reading the old `pendingPatches` value.
    private struct ApplyContext: Identifiable {
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
            Divider()
            if showOnboarding {
                onboardingWizard
            } else {
                transcriptScroll
                Divider()
                inputBar
            }
        }
        .task { await refreshProvider() }
        .onChange(of: project.id) { _, _ in
            transcript.removeAll()
            loadedContext = nil
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

    /// Shows the picker the first time the Assistant tab is opened, OR
    /// any time the user manually re-opens it via the status-bar button,
    /// OR when no provider is available. Persisted via UserDefaults so
    /// the choice sticks across launches but the user can revisit.
    private var showOnboarding: Bool {
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
                    Text("Three options. Pick one — you can change it later via the toggle in the chat header.")
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
                    description: String(localized: "Paste an Anthropic API key. Stored in macOS Keychain. Best answer quality for code-config audits. ~$0.001 per chat at Sonnet rates — cents per month for normal use."),
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
            Text("Affects the API-key provider only — Apple Intelligence has one model, and Claude (subscription) inherits whatever claude.ai picks.")
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
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func providerCard(
        kind: AIProviderKind,
        title: String,
        badge: String,
        description: String,
        requiresExtra: Bool,
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
                    .background(.quaternary, in: Capsule())
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    pickProvider(kind, requiresExtra: requiresExtra)
                } label: {
                    Text(requiresExtra
                         ? String(localized: "Set up")
                         : String(localized: "Use this"))
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(disabled)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pickProvider(_ kind: AIProviderKind, requiresExtra: Bool) {
        AIProviderRegistry.shared.preferredKind = kind
        UserDefaults.standard.set(true, forKey: "assistantOnboardingDone")
        forceShowOnboarding = false
        if requiresExtra && kind == .claudeAPIKey {
            // Pop the meter dropdown's General settings so the user can
            // paste their key. The Project window stays open behind it.
            if let url = URL(string: "throttle://settings/ai") {
                NSWorkspace.shared.open(url)
            }
        }
        Task { await refreshProvider() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            switch providerStatus {
            case .resolving:
                Text("Resolving AI provider…")
                    .font(.caption).foregroundStyle(.secondary)
            case .ready(let name):
                Text(name).font(.caption.weight(.semibold))
                Text("·").foregroundStyle(.tertiary)
                Text(project.displayName).font(.caption).foregroundStyle(.secondary)
            case .unavailable:
                Text("No AI provider configured")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Configure") { openProviderSettings() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Spacer()
            Button {
                Task { await runLocalAudit() }
            } label: {
                Image(systemName: "checklist").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(isStreaming)
            .help(String(localized: "Run local audit (no AI, no tokens)"))
            Button {
                exportDiagnosticsToDesktop()
            } label: {
                Image(systemName: "ladybug").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Export diagnostics to Desktop"))
            Button {
                forceShowOnboarding = true
            } label: {
                Image(systemName: "switch.2").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Switch AI provider"))
            Button {
                transcript.removeAll()
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(transcript.isEmpty || isStreaming)
            .help(String(localized: "Clear conversation"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcript.isEmpty {
                        emptyState
                            .padding(.top, 40)
                    }
                    ForEach(transcript) { msg in
                        if isSyntheticToolResult(msg) {
                            // Show a compact, collapsible card listing
                            // which files the AI fetched. Hides the raw
                            // bytes by default (they're noise) but lets
                            // the user expand to inspect.
                            toolResultCard(msg)
                                .id(msg.id)
                        } else {
                            bubble(msg)
                                .id(msg.id)
                        }
                    }
                    if !followUpSuggestions.isEmpty {
                        followUpChips
                    }
                }
                .padding(16)
            }
            .onChange(of: transcript.last?.id) { _, newID in
                guard let id = newID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func isSyntheticToolResult(_ msg: ChatMessage) -> Bool {
        msg.role == .user && msg.content.hasPrefix("[tool_result for ")
    }

    /// Compact card shown in place of the synthetic `[tool_result for …]`
    /// user message. The raw text is noise (the AI is the consumer), but
    /// users want to see *what was fetched* — both for trust ("did it
    /// read my settings?") and debugging ("why did it answer wrong?
    /// maybe it read the wrong file"). One row per tool call, with a
    /// disclosure arrow to peek at the bytes.
    @ViewBuilder
    private func toolResultCard(_ msg: ChatMessage) -> some View {
        let entries = parseToolResultEntries(from: msg.content)
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries.indices, id: \.self) { idx in
                    let e = entries[idx]
                    let key = "\(msg.id.uuidString)-\(idx)"
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedToolResults.contains(key) },
                        set: { isOpen in
                            if isOpen { expandedToolResults.insert(key) }
                            else { expandedToolResults.remove(key) }
                        }
                    )) {
                        ScrollView(.vertical) {
                            Text(e.body)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 240)
                        .background(.quaternary.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 6))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: toolIcon(e.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(e.tool)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(e.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private struct ToolResultEntry {
        let tool: String
        let path: String
        let body: String
    }

    private func toolIcon(_ tool: String) -> String {
        switch tool {
        case "read_file":  return "doc.text"
        case "list_files": return "folder"
        case "bash":       return "terminal"
        default:           return "wrench.and.screwdriver"
        }
    }

    /// Parse a synthetic `[tool_result for read_file (/path/to/file)]\n…`
    /// message back into structured entries. The format is produced by
    /// `runAssistantTurn` when batching tool results — each entry is
    /// separated by `\n\n---\n\n` and starts with the header line above.
    private func parseToolResultEntries(from content: String) -> [ToolResultEntry] {
        let chunks = content.components(separatedBy: "\n\n---\n\n")
        var out: [ToolResultEntry] = []
        for chunk in chunks {
            guard let nl = chunk.firstIndex(of: "\n") else { continue }
            let header = String(chunk[..<nl])
            let body = String(chunk[chunk.index(after: nl)...])
            // Header looks like: [tool_result for read_file (/path/to/file)]
            guard header.hasPrefix("[tool_result for ") else { continue }
            let inner = header
                .replacingOccurrences(of: "[tool_result for ", with: "")
                .replacingOccurrences(of: "]", with: "")
            // inner = "read_file (/path/to/file)"
            guard let openParen = inner.firstIndex(of: "("),
                  let closeParen = inner.lastIndex(of: ")") else { continue }
            let tool = String(inner[..<openParen]).trimmingCharacters(in: .whitespaces)
            let pathStart = inner.index(after: openParen)
            let path = String(inner[pathStart..<closeParen])
            out.append(ToolResultEntry(tool: tool, path: path, body: body))
        }
        return out
    }

    /// Click-able follow-up chips after an Apply summary. Tap one and
    /// it auto-submits as the next user message — no retyping. We wipe
    /// the suggestions on first interaction so the user isn't tempted
    /// to click an outdated one after they've moved on.
    private var followUpChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Continue")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            ForEach(followUpSuggestions, id: \.self) { suggestion in
                Button {
                    input = suggestion
                    followUpSuggestions = []
                    Task { await send() }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(.tint)
                        Text(suggestion)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Ask about this project")
                .font(.headline)
            Text("Pick a starter or type your own question.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                        Task { await send() }
                    } label: {
                        Text(prompt)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: 460, alignment: .leading)
                            .background(.quaternary.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    /// Hand-picked starter prompts. Each one is calibrated to produce a
    /// useful response with patches: concrete, scoped, and grounded in
    /// the project's actual files. Order = highest-impact first.
    private var suggestedPrompts: [String] {
        [
            String(localized: "Audit my setup. Find the 5 highest-impact changes to cut cost and tighten security."),
            String(localized: "Trouve les permissions dangereuses dans mon settings.json et propose des patches."),
            String(localized: "Mon CLAUDE.md est-il bien structuré pour ce projet ? Suggère ce qui manque."),
            String(localized: "Pourquoi mon model split est dominé par Opus ? Comment basculer vers Sonnet par défaut ?")
        ]
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        let isWaiting = msg.role == .assistant
            && msg.id == streamingMessageID
            && msg.content.isEmpty
        let patches = msg.role == .assistant
            ? AssistantPatchParser.extract(from: msg.content)
            : []
        let toolCalls = msg.role == .assistant
            ? AssistantToolCallParser.extract(from: msg.content)
            : []
        return HStack(alignment: .top, spacing: 10) {
            if msg.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.role == .user ? String(localized: "You") : String(localized: "Assistant"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isWaiting {
                    TypingIndicator()
                } else if msg.role == .assistant, let rendered = renderedMarkdown(stripPatchBlocks(msg.content)) {
                    Text(rendered)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(stripPatchBlocks(msg.content))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(toolCalls, id: \.self) { call in
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(call.tool.rawValue)
                            .font(.caption.weight(.semibold).monospaced())
                        Text(call.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.tint.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 6))
                }
                if !patches.isEmpty {
                    Button {
                        applyContext = ApplyContext(patches: patches)
                    } label: {
                        Label("Review & apply \(patches.count) change\(patches.count == 1 ? "" : "s")",
                              systemImage: "wand.and.rays")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(msg.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            if msg.role != .user { Spacer(minLength: 60) }
        }
    }

    /// Render assistant text as Markdown when possible (the Claude web
    /// session returns headings, lists, code spans, bold, etc.). Falls
    /// back to plain text if parsing fails.
    private func renderedMarkdown(_ s: String) -> AttributedString? {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try? AttributedString(markdown: s, options: opts)
    }

    /// Remove ```patch and ```tool fenced blocks from the bubble's
    /// prose. We surface patches as Apply cards and tool calls as
    /// inline "🔧 Read file: <path>" badges; the raw fence syntax
    /// would just clutter the chat.
    private func stripPatchBlocks(_ s: String) -> String {
        var stripped = s
        for pattern in ["```patch\\s*\\n.*?\\n```\\s*",
                        "```tool\\s*\\n.*?\\n```\\s*"] {
            guard let re = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            stripped = re.stringByReplacingMatches(
                in: stripped, options: [], range: range, withTemplate: ""
            )
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $input)
                .font(.callout)
                .frame(minHeight: 38, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend && !isStreaming)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool {
        guard case .ready = providerStatus else { return false }
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    // MARK: - Actions

    private func refreshProvider() async {
        providerStatus = .resolving
        let provider = await AIProviderRegistry.shared.resolveActive()
        if let provider {
            providerStatus = .ready(name: provider.displayName)
        } else {
            providerStatus = .unavailable
        }
    }

    private func openProviderSettings() {
        // Settings live inside the dropdown for now (fast path);
        // a dedicated AI settings sheet will land alongside the
        // Optimizer tab in v2.2.
        if let url = URL(string: "throttle://settings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func send() async {
        if isStreaming { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let provider = await AIProviderRegistry.shared.resolveActive() else {
            providerStatus = .unavailable
            return
        }

        let userMsg = ChatMessage(role: .user, content: text)
        transcript.append(userMsg)
        input = ""

        // Tag this whole turn (and any recursive tool-result follow-ups)
        // with one session id. ClaudeWebSessionProvider keys its
        // conversation cache off this — first call creates a claude.ai
        // conv, subsequent calls reuse it so we don't re-send the system
        // prompt and stay under their soft prompt-size limit.
        let sid = UUID()
        await ClaudeWebSessionScope.$sessionId.withValue(sid) {
            await runAssistantTurn(provider: provider, depth: 0, triedKinds: [])
        }
        await ClaudeWebSessionStore.shared.clear(sid)
        await APIKeyToolStateStore.shared.clear(sid)
    }

    /// One assistant turn — possibly followed by recursive tool-result
    /// turns up to a small depth limit. We always start with a fresh
    /// assistant bubble in the transcript; if the response contains
    /// `\`\`\`tool` calls, we execute them and re-invoke ourselves with
    /// a synthetic user message containing the tool result.
    ///
    /// `triedKinds` tracks providers we already attempted in this user
    /// turn. When a provider fails with a recoverable error (claude.ai
    /// dropped the response, Safari tab zombie, etc.) we ask the
    /// registry for the next available provider not in the set and
    /// transparently retry — Apple Intelligence is on-device and
    /// always available on macOS 26+, so the user almost never has to
    /// see "claude.ai dropped the response, please switch manually."
    private func runAssistantTurn(provider: any AIProvider, depth: Int, triedKinds: Set<AIProviderKind>) async {
        // Hard-cap recursion. The system prompt asks the model to stay
        // under 5 tool calls per request; this stops a runaway loop if
        // the model mis-parses our results.
        let maxDepth = 5
        if depth > maxDepth {
            let bubble = ChatMessage(role: .assistant, content: "Hit the tool-call limit (\(maxDepth)). Ask me again or rephrase if you need more inspection.")
            transcript.append(bubble)
            isStreaming = false
            streamingMessageID = nil
            return
        }

        let assistantMsg = ChatMessage(role: .assistant, content: "")
        transcript.append(assistantMsg)
        streamingMessageID = assistantMsg.id
        isStreaming = true

        let context = await ensureContext()
        do {
            let stream = try await provider.streamChat(messages: transcript, context: context)
            for try await delta in stream {
                appendDelta(delta, to: assistantMsg.id)
            }
        } catch {
            // If the failure is recoverable (claude.ai drop, tab zombie,
            // Safari not signed in, etc.) and another provider is
            // available, transparently fall back to it. The user gets
            // a working answer instead of a polite "go switch yourself."
            if let providerErr = error as? AIProviderError,
               providerErr.isRecoverable {
                var nextTried = triedKinds
                nextTried.insert(provider.kind)
                if let fallback = await AIProviderRegistry.shared.firstAvailable(excluding: nextTried) {
                    appendDelta(
                        "\n\n_\(provider.displayName) couldn't finish — falling back to \(fallback.displayName)._\n\n",
                        to: assistantMsg.id
                    )
                    // Drop the now-half-empty assistant message; the
                    // fallback will append a fresh one. Keep the
                    // fallback note visible by leaving the current
                    // bubble in place but stripping its trailing tool
                    // markers so the recursive call doesn't re-trigger
                    // on a stale tool block.
                    isStreaming = false
                    streamingMessageID = nil
                    await runAssistantTurn(provider: fallback, depth: depth, triedKinds: nextTried)
                    return
                }
            }
            // Hard error or no fallback — surface as a soft note
            // rather than a [Error: ...] which reads as a Throttle bug.
            // The error text from describe(...) is already user-ready.
            appendDelta("\n\n_\(error.localizedDescription)_", to: assistantMsg.id)
            isStreaming = false
            streamingMessageID = nil
            return
        }

        // Did the assistant ask to call a tool? Execute and recurse.
        let finalText = transcript.last?.content ?? ""
        let calls = AssistantToolCallParser.extract(from: finalText)
        if !calls.isEmpty {
            // Execute every tool call sequentially. We feed all results
            // back to the model in ONE synthetic user message so the
            // model has the whole batch of context for its next turn.
            var resultBlocks: [String] = []
            for call in calls {
                let result = AssistantToolExecutor.execute(call)
                resultBlocks.append("[tool_result for \(call.tool.rawValue) (\(call.displayLabel))]\n\(result)")
            }
            let toolMsg = ChatMessage(
                role: .user,
                content: resultBlocks.joined(separator: "\n\n---\n\n")
            )
            transcript.append(toolMsg)
            await runAssistantTurn(provider: provider, depth: depth + 1, triedKinds: triedKinds)
        } else {
            isStreaming = false
            streamingMessageID = nil
        }
    }

    /// Drop a synthetic assistant message into the transcript after the
    /// Apply sheet closes, summarizing what landed and prompting the
    /// user to keep going. The user sees the result inline instead of
    /// having to reopen the sheet or remember the patch list.
    private func appendApplySummary(applied: Int, skipped: Int, total: Int) {
        guard total > 0 else { return }
        var lines: [String] = []
        if applied > 0 {
            lines.append("✅ Applied **\(applied)** of \(total) suggested changes. Backups are kept beside each file (`.bak.<ts>`) and centrally — Rollback in the Optimizer tab if anything looks off.")
        } else {
            lines.append("Skipped all \(total) suggested changes. Nothing was written to disk.")
        }
        if skipped > 0 && applied > 0 {
            lines.append("\(skipped) were skipped (either you chose Skip, or the SEARCH text didn't match the file as currently on disk).")
        }
        let summary = ChatMessage(role: .assistant, content: lines.joined(separator: "\n"))
        transcript.append(summary)
        // Surface the follow-up suggestions as clickable chips below the
        // summary bubble so the user can keep the conversation going
        // without retyping. Tracked via @State so the Assistant view can
        // render them after the bubble.
        followUpSuggestions = [
            String(localized: "Verify the changes took effect by re-reading the files."),
            String(localized: "Audit the next-highest-impact finding from this conversation."),
            String(localized: "Look at CLAUDE.md, hooks, or MCP config now.")
        ]
        loadedContext = nil
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let idx = transcript.firstIndex(where: { $0.id == id }) else { return }
        let current = transcript[idx]
        transcript[idx] = ChatMessage(
            role: current.role,
            content: current.content + delta,
            id: current.id,
            timestamp: current.timestamp
        )
    }

    /// Build the project context once per session. Loads:
    /// - CLAUDE.md and .claude/settings.json from the project root
    /// - Globally-installed hook scripts from ~/.claude/hooks/
    /// - MCP server names from ~/.claude/settings.json (MCP config lives here)
    /// - Per-project tokens, cost, model split for the last 7 days
    private func ensureContext() async -> ProjectChatContext {
        if let loadedContext { return loadedContext }
        let claudeMd = project.claudeMdURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let settingsJSON = project.settingsJSONURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let database = appState.database
        let encoded = project.encodedName

        struct StatsBundle: Sendable {
            var weekly: Int = 0
            var split: [(String, Double)] = []
            var cost: Double = 0
        }
        let stats: StatsBundle = await Task.detached {
            var s = StatsBundle()
            _ = try? database.read { db in
                s.weekly = (try? StatsDataService.tokensForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
                s.split = (try? StatsDataService.modelSplitForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? []
                s.cost = (try? StatsDataService.costForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
            }
            return s
        }.value

        // Read global hooks the user has installed and the MCP server
        // list out of ~/.claude/. These are shared across all projects
        // so we always include them in every project's context.
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let hooksDir = claudeDir.appendingPathComponent("hooks", isDirectory: true)
        var hookScripts: [String: String] = [:]
        var hookScriptPaths: [String: String] = [:]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: hooksDir.path) {
            for name in entries where name.hasSuffix(".sh") {
                let url = hooksDir.appendingPathComponent(name)
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let key = "~/.claude/hooks/\(name)"
                    hookScripts[key] = content
                    hookScriptPaths[key] = url.path
                }
            }
        }
        var mcpServers: [String] = []
        let globalSettingsURL = claudeDir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: globalSettingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let mcps = obj["mcpServers"] as? [String: Any] {
            mcpServers = mcps.keys.sorted()
        }

        var ctx = ProjectChatContext(
            projectName: project.displayName,
            projectPath: project.projectPath,
            claudeMd: claudeMd,
            settingsJSON: settingsJSON,
            weeklyTokens: stats.weekly,
            modelSplit: stats.split,
            hookScripts: hookScripts,
            mcpServers: mcpServers,
            costEUR: stats.cost
        )
        ctx.claudeMdPath = project.claudeMdURL?.path
        ctx.settingsJSONPath = project.settingsJSONURL?.path
        ctx.hookScriptPaths = hookScriptPaths
        loadedContext = ctx
        return ctx
    }

    /// Run the deterministic 7-rule audit (LocalAuditEngine) and post the
    /// findings as a synthetic assistant message. No AI tokens consumed.
    /// The output uses the same Markdown shape the AI uses, so the user
    /// can't tell from the chat UI which engine produced the answer —
    /// the only difference is the toolbar button they pressed.
    private func runLocalAudit() async {
        // Show a "user" bubble so the chat looks like a real turn —
        // makes the result feel like an answer to a question.
        let userMsg = ChatMessage(role: .user, content: String(localized: "Run local audit (deterministic, no AI)."))
        transcript.append(userMsg)

        let claudeMdText = project.claudeMdURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let claudeMdBytes: Int = project.claudeMdURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let settingsJSONText = project.settingsJSONURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        let hooksDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks", isDirectory: true)
        let hooksPresent: [String]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: hooksDir.path) {
            hooksPresent = entries.filter { $0.hasSuffix(".sh") }
        } else {
            hooksPresent = []
        }

        let claudeMdPair: (text: String, bytes: Int)? = {
            guard let text = claudeMdText else { return nil }
            return (text: text, bytes: claudeMdBytes > 0 ? claudeMdBytes : text.utf8.count)
        }()

        let findings = LocalAuditEngine.audit(
            claudeMd: claudeMdPair,
            settingsJSON: settingsJSONText,
            hooksPresent: hooksPresent
        )
        let markdown = LocalAuditEngine.renderMarkdown(findings: findings)
        transcript.append(ChatMessage(role: .assistant, content: markdown))
    }

    /// Export the diagnostics bundle to ~/Desktop/ via the existing
    /// `DiagnosticsExporter` and post a one-line confirmation in the
    /// chat. The bundle contains DB snapshot, recent crash logs, and
    /// app state — no AI involvement, suitable for emailing support.
    private func exportDiagnosticsToDesktop() {
        let database = appState.database
        let confirmation: String
        if let url = DiagnosticsExporter.exportToDesktop(database: database) {
            confirmation = String(localized: "Diagnostics exported to ") + url.path
            // Reveal in Finder so the user can find it without hunting.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            confirmation = String(localized: "Diagnostics export failed — check the app log.")
        }
        transcript.append(ChatMessage(role: .assistant, content: "_\(confirmation)_"))
    }
}

/// Three pulsing dots shown while the assistant message hasn't started
/// streaming yet. Plain SwiftUI animation — no Canvas, no Metal.
private struct TypingIndicator: View {
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
