import SwiftUI

/// A GitHub-style unified line diff: added lines green (+), removed red (−),
/// unchanged neutral. Read-only. Used by the AI Optimizer's "commit mode" so
/// you see exactly what a proposal changes before applying.
enum DiffKind { case same, added, removed }

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffKind
    let text: String
}

enum LineDiff {
    /// LCS line diff. O(n·m) — fine for config files (hundreds of lines).
    static func compute(_ oldText: String, _ newText: String) -> [DiffLine] {
        let a = oldText.components(separatedBy: "\n")
        let b = newText.components(separatedBy: "\n")
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { out.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
            else { out.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        }
        while i < n { out.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
        while j < m { out.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        return out
    }

    static func counts(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(line.kind))
                            .frame(width: 10, alignment: .center)
                            .foregroundStyle(markerColor(line.kind))
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(line.kind == .same ? .secondary : .primary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12).monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func marker(_ k: DiffKind) -> String {
        switch k { case .added: return "+"; case .removed: return "−"; case .same: return "" }
    }
    private func markerColor(_ k: DiffKind) -> Color {
        switch k { case .added: return .green; case .removed: return .red; case .same: return .clear }
    }
    private func background(_ k: DiffKind) -> Color {
        switch k {
        case .added:   return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .same:    return .clear
        }
    }
}
