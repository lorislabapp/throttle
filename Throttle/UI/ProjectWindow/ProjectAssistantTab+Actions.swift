import AppKit
import SwiftUI

extension ProjectAssistantTab {
    var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $input)
                .accessibilityIdentifier("project-assistant-input")
                .accessibilityLabel(String(localized: "Message to the project Assistant"))
                .font(.callout)
                .frame(minHeight: 38, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(chipBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hair, lineWidth: 1))
            Button {
                if sendTask != nil { stopResponse(showNotice: true) } else { startSend() }
            } label: {
                Image(systemName: sendTask != nil ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend || sendTask != nil ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!canSend && sendTask == nil)
            .accessibilityIdentifier(sendTask != nil ? "project-assistant-stop" : "project-assistant-send")
            .accessibilityLabel(sendTask != nil
                                ? String(localized: "Stop response") : String(localized: "Send message"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var canSend: Bool {
        guard case .ready = providerStatus else { return false }
        return !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sendTask == nil && !isStreaming
    }

    // MARK: - Actions

    private func resolveProvider() async -> (any AIProvider)? {
        if let runtimeOverride { return runtimeOverride.provider }
        return await AIProviderRegistry.shared.resolveActive()
    }

    func refreshProvider() async {
        providerStatus = .resolving
        let provider = await resolveProvider()
        if let provider {
            providerStatus = .ready(name: provider.displayName)
        } else {
            providerStatus = .unavailable
        }
    }

    func openProviderSettings() {
        // Settings live inside the dropdown for now (fast path);
        // a dedicated AI settings sheet will land alongside the
        // Optimizer tab in v2.2.
        if let url = URL(string: "throttle://settings") {
            NSWorkspace.openInBackground(url)
        }
    }

    func startSend() {
        guard sendTask == nil, canSend else { return }
        let generation = UUID()
        sendGeneration = generation
        sendTask = Task {
            await send()
            guard sendGeneration == generation else { return }
            sendTask = nil
            sendGeneration = nil
            isStreaming = false
            streamingMessageID = nil
        }
    }

    func stopResponse(showNotice: Bool = false) {
        if showNotice, let id = streamingMessageID {
            let note = String(localized: "Response stopped. A remote provider may still be finishing its request.")
            appendDelta("\n\n_\(note)_", to: id)
        }
        sendTask?.cancel()
        sendTask = nil
        sendGeneration = nil
        isStreaming = false
        streamingMessageID = nil
    }

    private func send() async {
        if isStreaming || Task.isCancelled { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let provider = await resolveProvider() else {
            if !Task.isCancelled { providerStatus = .unavailable }
            return
        }
        guard !Task.isCancelled else { return }

        let userMsg = ChatMessage(role: .user, content: text)
        transcript.append(userMsg)
        input = ""

        // Tag this whole turn (and any recursive tool-result follow-ups)
        // with one session id. ClaudeWebSessionProvider keys its
        // conversation cache off this — first call creates a claude.ai
        // conv, subsequent calls reuse it so we don't re-send the system
        // prompt and stay under their soft prompt-size limit.
        let sid = UUID()
        let context = await ensureContext()
        guard !Task.isCancelled else { return }
        let scope = AssistantProjectTools(projectPath: context.projectPath)
        await AssistantProjectToolScope.$current.withValue(scope) {
            await ClaudeWebSessionScope.$sessionId.withValue(sid) {
                await runAssistantTurn(provider: provider, depth: 0, triedKinds: [])
            }
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
        guard !Task.isCancelled else { return }
        // Hard-cap recursion. The system prompt asks the model to stay
        // under 5 tool calls per request; this stops a runaway loop if
        // the model mis-parses our results.
        let maxDepth = 5
        if depth > maxDepth {
            let bubble = ChatMessage(role: .assistant, content: """
                Hit the tool-call limit (\(maxDepth)). Ask me again or rephrase if you need \
                more inspection.
                """)
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
        guard !Task.isCancelled else { return }
        let projectTools = AssistantProjectToolScope.current ?? AssistantProjectTools(projectPath: context.projectPath)
        do {
            let stream = try await provider.streamChat(messages: transcript, context: context)
            for try await delta in stream {
                try Task.checkCancellation()
                appendDelta(delta, to: assistantMsg.id)
            }
            try Task.checkCancellation()
        } catch {
            await handleAssistantError(error, provider: provider, depth: depth,
                                       triedKinds: triedKinds, messageID: assistantMsg.id)
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
                guard !Task.isCancelled else { return }
                let result = projectTools.execute(call)
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

    private func handleAssistantError(_ error: Error, provider: any AIProvider, depth: Int,
                                      triedKinds: Set<AIProviderKind>, messageID: UUID) async {
            guard !Task.isCancelled else { return }
        // If the failure is recoverable (claude.ai drop, tab zombie,
        // Safari not signed in, etc.) and another provider is
        // available, transparently fall back to it. The user gets
        // a working answer instead of a polite "go switch yourself."
        if runtimeOverride == nil, let providerErr = error as? AIProviderError,
           providerErr.isRecoverable {
            var nextTried = triedKinds
            nextTried.insert(provider.kind)
            if let fallback = await AIProviderRegistry.shared.firstAvailable(excluding: nextTried) {
                guard !Task.isCancelled else { return }
                let why = (error as? AIProviderError)?.errorDescription ?? error.localizedDescription
                let note = fallback.displayName.contains("Apple Intelligence")
                    ? """
                        \n\n_\(provider.displayName) couldn't finish: \(why)\n\nFalling back to \
                        \(fallback.displayName) — a small on-device model, so the answer is lighter. \
                        Add a Claude API key in settings for the full analysis._\n\n
                        """
                    : """
                        \n\n_\(provider.displayName) couldn't finish: \(why) — falling back to \
                        \(fallback.displayName)._\n\n
                        """
                appendDelta(note, to: messageID)
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
        guard !Task.isCancelled else { return }
        // Hard error or no fallback — surface as a soft note
        // rather than a [Error: ...] which reads as a Throttle bug.
        // The error text from describe(...) is already user-ready.
        appendDelta("\n\n_\(error.localizedDescription)_", to: messageID)
        isStreaming = false
        streamingMessageID = nil
        return
    }

    /// Drop a synthetic assistant message into the transcript after the
    /// Apply sheet closes, summarizing what landed and prompting the
    /// user to keep going. The user sees the result inline instead of
    /// having to reopen the sheet or remember the patch list.
    func appendApplySummary(applied: Int, skipped: Int, total: Int) {
        guard total > 0 else { return }
        var lines: [String] = []
        if applied > 0 {
            lines.append("""
                ✅ Applied **\(applied)** of \(total) suggested changes. Backups are kept \
                beside each file (`.bak.<ts>`) and centrally — Rollback in the Optimizer tab \
                if anything looks off.
                """)
        } else {
            lines.append("Skipped all \(total) suggested changes. Nothing was written to disk.")
        }
        if skipped > 0 && applied > 0 {
            lines.append("""
                \(skipped) were skipped (either you chose Skip, or the SEARCH text didn't \
                match the file as currently on disk).
                """)
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

}
