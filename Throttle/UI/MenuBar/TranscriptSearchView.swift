import SwiftUI
import AppKit

/// Search your OWN past Claude Code sessions directly (no Claude in the loop) —
/// full-text over ~/.claude transcripts. Type a query, get ranked snippets with
/// project + date. The data layer is TranscriptIndex (FTS5, local).
struct TranscriptSearchView: View {
    var onDone: () -> Void = {}

    @State private var query = ""
    @State private var hits: [TranscriptHit] = []
    @State private var searching = false
    @State private var indexed = false
    @State private var searchToken = 0

    private let hair = Color.primary.opacity(0.09)
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 580, height: 540)
        .onAppear { warmIndex() }
        .onChange(of: query) { _, _ in scheduleSearch() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search your past sessions…", text: $query)
                .textFieldStyle(.plain).font(.system(size: 14))
            if searching { ProgressView().controlSize(.small) }
            Button("Done") { onDone() }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).count < 2 {
            placeholder(icon: "clock.arrow.circlepath",
                        title: "Search everything you've done with Claude Code",
                        sub: indexed ? "Type a keyword, an error, a decision — it searches all your past sessions, locally."
                                     : "Building the index of your past sessions…")
        } else if hits.isEmpty && !searching {
            placeholder(icon: "magnifyingglass", title: "No matches", sub: "Nothing in your past sessions for \u{201C}\(query)\u{201D}.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(hits) { hit in
                        row(hit)
                        Rectangle().fill(hair).frame(height: 1)
                    }
                }
            }
        }
    }

    private func row(_ h: TranscriptHit) -> some View {
        Button {
            // Reveal the session transcript in Finder.
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
            if let dir = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .first(where: { (try? FileManager.default.contentsOfDirectory(atPath: $0.path).contains("\(h.sessionId).jsonl")) == true }) {
                NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("\(h.sessionId).jsonl")])
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(h.project).font(.system(size: 11.5, weight: .semibold))
                    Text(h.role.uppercased()).font(.system(size: 8.5, weight: .heavy)).tracking(0.3)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(fmt.string(from: h.timestamp)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(snippetAttr(h.snippet)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Reveal this session's transcript in Finder")
    }

    /// Render the «…» FTS5 highlight markers as accent-colored emphasis.
    private func snippetAttr(_ s: String) -> AttributedString {
        var out = AttributedString()
        var emphasized = false
        for part in s.components(separatedBy: CharacterSet(charactersIn: "\u{00AB}\u{00BB}")) {
            var piece = AttributedString(part)
            if emphasized { piece.foregroundColor = .accentColor; piece.font = .system(size: 12, weight: .semibold) }
            out += piece
            emphasized.toggle()
        }
        return out
    }

    private func placeholder(icon: String, title: String, sub: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search (debounced, off-main)

    private func warmIndex() {
        Task.detached(priority: .utility) {
            _ = TranscriptIndex.reindex()
            await MainActor.run { indexed = true }
        }
    }

    private func scheduleSearch() {
        searchToken += 1
        let token = searchToken
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { hits = []; return }
        searching = true
        Task {
            try? await Task.sleep(for: .milliseconds(180))   // debounce
            guard token == searchToken else { return }
            let results = await Task.detached(priority: .userInitiated) { TranscriptIndex.search(q, limit: 40) }.value
            guard token == searchToken else { return }
            hits = results
            searching = false
        }
    }
}
