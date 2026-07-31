import SwiftUI

/// Read-Firewall readout. Detection is automatic and local; deployment remains an
/// explicit user action because semantic retrieval changes what reaches the model.
struct ReadFirewallReadout: View {
    let project: ProjectInfo

    @State private var s = ReadFirewallScanner.Summary()
    @State private var installed = false
    @State private var installError: String?
    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        Group {
            if s.hasData {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("READ PRESSURE")
                            .font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text("local logs · last 14d")
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
                        cell(ByteCountFormatter.string(fromByteCount: Int64(s.loadedBytes),
                                                       countStyle: .file), "loaded")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    Text("This workspace crossed the read firewall threshold (≥\(ReadFirewallScanner.heavyThreshold) sequential reads or >150 KB in one turn). Deployment is explicit and reversible; nothing leaves your Mac.")
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
            if let root = ProjectsService.decodePath(enc) {
                installed = MCPConfigService.list().contains {
                    $0.name == ReadFirewallInstaller.serverName
                        && $0.scope == .project(projectPath: root)
                        && !$0.disabled
                }
            }
        }
    }

    /// Connects detection → the EXISTING local semantic engine. Enabling just flips
    /// Throttle's own opt-in index toggle (SemanticAutoIndexer) and kicks a one-time
    /// index of THIS repo — it does not touch the project's .mcp.json or send anything
    /// off-device. Claude then has throttle_semantic_search available for this repo.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if installed {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                Text("mcp-local-rag added — restart Claude Code to load it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Button {
                    guard let root = ProjectsService.decodePath(project.encodedName) else { return }
                    do {
                        _ = try ReadFirewallInstaller.install(projectPath: root)
                        installed = true
                    } catch {
                        installError = error.localizedDescription
                    }
                } label: {
                    Text("Deploy local read firewall").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Text("MiniLM-L6-v2 · LanceDB · opt-in").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        if let installError {
            Text(installError).font(.system(size: 9.5)).foregroundStyle(.orange)
        }
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
        }
    }
}
