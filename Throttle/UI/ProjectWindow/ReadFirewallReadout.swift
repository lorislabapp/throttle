import SwiftUI

/// Read-Firewall readout — measure-only, per project. Surfaces the brute-force
/// read signature (`ReadFirewallScanner`) so you can scope reads or add local
/// semantic retrieval. Detection + attribution only: Throttle never rewires the
/// project's `.mcp.json` (semantic recall is lossy — that stays your call). Hidden
/// when there's nothing notable, muted tone, `≈`/"measure-only" per the golden rule.
struct ReadFirewallReadout: View {
    let project: ProjectInfo

    @State private var s = ReadFirewallScanner.Summary()
    @State private var indexOn = SemanticAutoIndexer.isEnabled
    @State private var indexing = false
    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        Group {
            if s.hasData {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("READ PRESSURE")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text("measure-only · last 14d")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if let f = s.topFile {
                            Text("mostly \(f) ×\(s.topFileCount)")
                                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    HStack(spacing: 18) {
                        cell("\(s.heavyTurns)", "heavy turns")
                        cell("\(s.totalReads)", "file reads")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    Text("This project loads whole files in bulk (≥\(ReadFirewallScanner.heavyThreshold) reads/turn). Throttle already ships a 100%-local semantic index — turn it on and Claude can search this repo by meaning via throttle_semantic_search instead of re-reading whole files. No config rewrite; nothing leaves your Mac.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    actionRow.padding(.top, 7)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(hair).frame(height: 1)
            }
        }
        .task(id: project.encodedName) {
            let enc = project.encodedName
            s = await Task.detached(priority: .utility) { ReadFirewallScanner.scan(encodedName: enc) }.value
        }
    }

    /// Connects detection → the EXISTING local semantic engine. Enabling just flips
    /// Throttle's own opt-in index toggle (SemanticAutoIndexer) and kicks a one-time
    /// index of THIS repo — it does not touch the project's .mcp.json or send anything
    /// off-device. Claude then has throttle_semantic_search available for this repo.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if indexOn {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                Text(indexing ? "Indexing this repo…" : "Semantic index on — Claude can search here by meaning.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button {
                    SemanticAutoIndexer.isEnabled = true
                    indexOn = true; indexing = true
                    let root = project.projectPath
                    let quiet = MemoryPressureMonitor.shared.isQuiet   // read on main
                    Task.detached(priority: .utility) {
                        if let root, !root.isEmpty {
                            _ = SemanticAutoIndexer.run(roots: [root], enabled: true,
                                                        memoryQuiet: quiet,
                                                        embedder: NLEmbeddingProvider())
                        }
                        await MainActor.run { indexing = false }
                    }
                } label: {
                    Text("Enable semantic index").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Text("100% local · opt-in · reversible").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
        }
    }
}
