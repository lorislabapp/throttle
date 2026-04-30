import Foundation

/// One concrete file-edit suggestion the assistant proposed in chat.
/// Extracted from a `PATCH` fenced block in the assistant's markdown
/// response. The user reviews each patch in the Apply sheet and either
/// accepts (FileEditor writes it with backup + verify), skips, or stops
/// the apply queue.
struct AssistantPatch: Sendable, Identifiable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case replace  // SEARCH text in existing file → REPLACE with new text
        case create   // Create a NEW file with CONTENT (file must not exist)
    }

    let id: UUID
    let kind: Kind
    let filePath: String
    /// SEARCH text (for .replace) or empty (for .create).
    let search: String
    /// Replacement text (.replace) or full new-file body (.create).
    let replace: String
    let reason: String

    init(kind: Kind = .replace, filePath: String, search: String, replace: String, reason: String) {
        self.id = UUID()
        self.kind = kind
        self.filePath = filePath
        self.search = search
        self.replace = replace
        self.reason = reason
    }
}

/// Pulls `AssistantPatch` items out of the assistant's markdown reply.
/// Strict format the system prompt requires:
///
/// ```patch
/// FILE: /Users/kevin/.claude/settings.json
/// SEARCH:
/// "skipDangerousModePermissionPrompt": true
/// REPLACE:
/// "skipDangerousModePermissionPrompt": false
/// REASON: Re-enable the dangerous-mode guard.
/// ```
///
/// Any block missing FILE/SEARCH/REPLACE is silently dropped — we'd
/// rather miss a malformed patch than apply garbage to a real file.
enum AssistantPatchParser {
    static func extract(from text: String) -> [AssistantPatch] {
        var patches: [AssistantPatch] = []
        // Greedy match every fenced ```patch ... ``` block.
        let pattern = "```patch\\s*\\n(.*?)\\n```"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let m = match,
                  m.numberOfRanges >= 2,
                  let bodyRange = Range(m.range(at: 1), in: text) else { return }
            let body = String(text[bodyRange])
            if let patch = parseBody(body) {
                patches.append(patch)
            }
        }
        return patches
    }

    private static func parseBody(_ body: String) -> AssistantPatch? {
        var file: String?
        var search: String?
        var replace: String?
        var content: String?
        var reason = ""

        enum State { case idle, search, replace, content, reason }
        var state = State.idle
        var searchBuf = ""
        var replaceBuf = ""
        var contentBuf = ""

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("FILE:") {
                file = line.dropFirst("FILE:".count).trimmingCharacters(in: .whitespaces)
                state = .idle
            } else if line.hasPrefix("SEARCH:") {
                let inline = line.dropFirst("SEARCH:".count).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty {
                    searchBuf = inline
                    state = .idle
                } else {
                    state = .search
                }
            } else if line.hasPrefix("REPLACE:") {
                let inline = line.dropFirst("REPLACE:".count).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty {
                    replaceBuf = inline
                    state = .idle
                } else {
                    state = .replace
                }
            } else if line.hasPrefix("CREATE:") {
                let inline = line.dropFirst("CREATE:".count).trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty {
                    contentBuf = inline
                    state = .idle
                } else {
                    state = .content
                }
            } else if line.hasPrefix("REASON:") {
                let inline = line.dropFirst("REASON:".count).trimmingCharacters(in: .whitespaces)
                reason = inline
                state = .reason
            } else {
                switch state {
                case .search:
                    if !searchBuf.isEmpty { searchBuf += "\n" }
                    searchBuf += line
                case .replace:
                    if !replaceBuf.isEmpty { replaceBuf += "\n" }
                    replaceBuf += line
                case .content:
                    if !contentBuf.isEmpty { contentBuf += "\n" }
                    contentBuf += line
                case .reason:
                    if !reason.isEmpty { reason += " " }
                    reason += line.trimmingCharacters(in: .whitespaces)
                case .idle:
                    break
                }
            }
        }
        if !searchBuf.isEmpty { search = searchBuf }
        if !replaceBuf.isEmpty { replace = replaceBuf }
        if !contentBuf.isEmpty { content = contentBuf }

        guard let file, !file.isEmpty else { return nil }

        // CREATE block — no SEARCH/REPLACE, just CONTENT for a new file.
        if let content, !content.isEmpty, search == nil, replace == nil {
            return AssistantPatch(
                kind: .create,
                filePath: file,
                search: "",
                replace: content,
                reason: reason
            )
        }
        // REPLACE block — must have both SEARCH and REPLACE.
        if let search, let replace, !search.isEmpty {
            return AssistantPatch(
                kind: .replace,
                filePath: file,
                search: search,
                replace: replace,
                reason: reason
            )
        }
        return nil
    }
}
