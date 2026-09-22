import AppKit
import SwiftUI

extension ProjectAssistantTab {
    var statusBar: some View {
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
            .accessibilityLabel(String(localized: "Run local audit"))
            Button {
                DiagnosticsPreviewWindowController.shared.show(
                    report: DiagnosticsExporter.buildReport(database: appState.database),
                    onExport: DiagnosticsExporter.exportToDesktop(report:))
            } label: {
                Image(systemName: "ladybug").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Preview diagnostics"))
            .accessibilityLabel(String(localized: "Preview diagnostics"))
            Button {
                forceShowOnboarding = true
            } label: {
                Image(systemName: "switch.2").font(.caption)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Switch AI provider"))
            .accessibilityLabel(String(localized: "Switch AI provider"))
            Button {
                transcript.removeAll()
            } label: {
                Image(systemName: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(transcript.isEmpty || isStreaming)
            .help(String(localized: "Clear conversation"))
            .accessibilityLabel(String(localized: "Clear conversation"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var transcriptScroll: some View {
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
                            // bytes by default (they'expression noise) but lets
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
                    let entry = entries[idx]
                    let key = "\(msg.id.uuidString)-\(idx)"
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedToolResults.contains(key) },
                        set: { isOpen in
                            if isOpen { expandedToolResults.insert(key) } else { expandedToolResults.remove(key) }
                        }
                    )) {
                        ScrollView(.vertical) {
                            Text(entry.body)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 240)
                        .background(chipBG, in: RoundedRectangle(cornerRadius: 6))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: toolIcon(entry.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.tool)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.path)
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
        case "search_files": return "magnifyingglass"
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
            guard let newline = chunk.firstIndex(of: "\n") else { continue }
            let header = String(chunk[..<newline])
            let body = String(chunk[chunk.index(after: newline)...])
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
                    startSend()
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(.tint)
                        Text(suggestion)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(chipBG, in: RoundedRectangle(cornerRadius: 8))
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
                        startSend()
                    } label: {
                        Text(prompt)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: 460, alignment: .leading)
                            .background(chipBG, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hair, lineWidth: 1))
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
            String(localized: "Find unsafe permissions in my settings.json and suggest patches."),
            String(localized: "Is my CLAUDE.md well structured for this project? Suggest what is missing."),
            String(localized: "Why does Opus dominate my model usage? How can I make Sonnet the default?")
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
                toolBadges(toolCalls)
                if !patches.isEmpty {
                    Button {
                        applyContext = ApplyContext(patches: patches)
                    } label: {
                        Label("Review & apply \(patches.count) change(s)",
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

    private func toolBadges(_ toolCalls: [AssistantToolCall]) -> some View {
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
    }

    /// Render assistant text as Markdown when possible (the Claude web
    /// session returns headings, lists, code spans, bold, etc.). Falls
    /// back to plain text if parsing fails.
    private func renderedMarkdown(_ source: String) -> AttributedString? {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return try? AttributedString(markdown: source, options: opts)
    }

    /// Remove ```patch and ```tool fenced blocks from the bubble's
    /// prose. We surface patches as Apply cards and tool calls as
    /// inline "🔧 Read file: <path>" badges; the raw fence syntax
    /// would just clutter the chat.
    private func stripPatchBlocks(_ source: String) -> String {
        var stripped = source
        for pattern in ["```patch\\s*\\n.*?\\n```\\s*",
                        "```tool\\s*\\n.*?\\n```\\s*"] {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            stripped = expression.stringByReplacingMatches(
                in: stripped, options: [], range: range, withTemplate: ""
            )
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
