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

    enum ProviderStatus: Equatable {
        case resolving
        case ready(name: String)
        case unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcriptScroll
            Divider()
            inputBar
        }
        .task { await refreshProvider() }
        .onChange(of: project.id) { _, _ in
            transcript.removeAll()
            loadedContext = nil
            Task { await refreshProvider() }
        }
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
                        bubble(msg)
                            .id(msg.id)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Ask about this project")
                .font(.headline)
            Text("Examples: \"Is my CLAUDE.md doing too much?\", \"Suggest a slimmer settings.json.\", \"Why am I burning so many Sonnet tokens this week?\"")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if msg.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.role == .user ? String(localized: "You") : String(localized: "Assistant"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(msg.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(msg.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            if msg.role != .user { Spacer(minLength: 60) }
        }
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
            appendDelta("\n\n[Error: \(error.localizedDescription)]", to: assistantMsg.id)
        }
        isStreaming = false
        streamingMessageID = nil
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

    /// Build the project context (CLAUDE.md + settings.json + stats) once
    /// per session. Refreshed when the user switches projects.
    private func ensureContext() async -> ProjectChatContext {
        if let loadedContext { return loadedContext }
        let claudeMd = project.claudeMdURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let settingsJSON = project.settingsJSONURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        let database = appState.database
        let encoded = project.encodedName

        struct StatsBundle: Sendable {
            var weekly: Int = 0
            var split: [(String, Double)] = []
        }
        let stats: StatsBundle = await Task.detached {
            var s = StatsBundle()
            _ = try? database.read { db in
                s.weekly = (try? StatsDataService.tokensForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? 0
                s.split = (try? StatsDataService.modelSplitForProject(in: db, encodedName: encoded, fromHoursAgo: 0, toHoursAgo: 168)) ?? []
            }
            return s
        }.value

        let ctx = ProjectChatContext(
            projectName: project.displayName,
            projectPath: project.projectPath,
            claudeMd: claudeMd,
            settingsJSON: settingsJSON,
            weeklyTokens: stats.weekly,
            modelSplit: stats.split
        )
        loadedContext = ctx
        return ctx
    }
}
