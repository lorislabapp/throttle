import SwiftUI

/// Per-technique savings ledger — the honest answer to "what exactly did Throttle
/// save me, and how?". Two tiers, never blended into one bold number:
///   • REALIZED (EXACT): a true before/after byte delta on the same tool output
///     (the tokopt hooks → `tokopt_savings`). Bytes are exact; tokens are ≈ because
///     we measure bytes, not the model's tokenizer.
///   • AVOIDABLE (≈EST): counterfactual weight you stop paying every turn/session
///     (dead-skill schema, TOON-compressible output). Estimates, with the method shown.
///
/// Golden rule: each row carries its own confidence tag and a one-line "how computed";
/// no line implies an exactness it doesn't have.
struct SavingsLedgerView: View {
    @Environment(AppState.self) private var appState

    @State private var realized: [StatsDataService.HookSaving] = []
    @State private var skills = SkillReport.empty
    @State private var toon = TOONTranspiler.Potential()
    @State private var rmcEUR: Double = 0
    @State private var archiving = false
    @State private var loaded = false

    private var deadSkillTokens: Int { skills.deadTokens }

    private var hair: Color { Color.primary.opacity(0.09) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // RMC hero — the one € number a user acts on: cash burned because bad prompt
            // hygiene forced a cache re-write instead of a 0.1× cache read (NotebookLM Q4).
            if rmcEUR >= 0.01 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "flame.fill").font(.system(size: 12)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("≈€\(String(format: "%.2f", rmcEUR)) burned this week re-writing a cache that should've been warm")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                        Text("A big cache write <5 min after the prior turn = the prefix got busted (dynamic injection / model swap / re-sorted tools), billed at 1.25× instead of 0.10×.")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            if loaded && realized.isEmpty && deadSkillTokens == 0 && !toon.hasData {
                Text("No savings measured yet. As Throttle's hooks process tool output, exact byte savings land here.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }

            if !realized.isEmpty {
                sectionLabel("REALIZED · MEASURED", "exact before/after on the same output · last 7d")
                ForEach(realized) { r in
                    row(label: techLabel(r.hook),
                        method: "\(r.records) hook fires · Σ exact byte delta",
                        bytes: r.bytes, exact: true)
                }
                totalRow("Realized total", bytes: realized.reduce(0) { $0 + $1.bytes }, exact: true)
            }

            if deadSkillTokens > 0 || toon.hasData {
                sectionLabel("AVOIDABLE · ESTIMATED", "counterfactual weight — not realized spend")
                if deadSkillTokens > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text("Dead skills (\(skills.deadCount), unused)").font(.system(size: 11.5, weight: .medium))
                                tag(false)
                            }
                            Text("SKILL.md bytes loaded every session — archive to stop paying")
                                .font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button(archiving ? "Archiving…" : "Archive \(skills.deadCount)") { archiveDead() }
                            .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor).disabled(archiving)
                            .help("Reversible move of every unused skill out of the load path, then rescan")
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("≈\(byteStr(deadSkillTokens))").font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text("≈\(tokenStr(deadSkillTokens / 4)) tok").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                }
                if toon.hasData {
                    row(label: "TOON-compressible output",
                        method: "\(toon.samples) samples · array→CSV would save this if Phase 2 ships",
                        bytes: toon.savedBytes, exact: false)
                }
            }
        }
        .task {
            guard !loaded else { return }
            await reload()
            loaded = true
        }
    }

    private func reload() async {
        let db = appState.database
        realized = (try? await Task.detached(priority: .utility) {
            try db.read { try StatsDataService.savedByHook(in: $0) }
        }.value) ?? []
        rmcEUR = (try? await Task.detached(priority: .utility) {
            try db.read { try StatsDataService.recoverableMissCostEUR(in: $0).eur }
        }.value) ?? 0
        skills = await Task.detached(priority: .utility) { SkillUsageService.scan() }.value
        toon = await Task.detached(priority: .utility) { TOONTranspiler.potentialSummary() }.value
    }

    /// 1-click remediation for the AVOIDABLE dead-skill row — archive every unused
    /// skill (reversible file move) then rescan so the ledger reflects the drop.
    private func archiveDead() {
        guard !archiving else { return }
        archiving = true
        let dead = skills.skills.filter { $0.dead }.map(\.name)
        Task {
            await Task.detached(priority: .utility) {
                for name in dead { _ = try? SkillUsageService.archive(skillName: name) }
            }.value
            await reload()
            archiving = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Savings ledger").font(.system(size: 13, weight: .semibold))
            Text("What Throttle saved, by technique. Bytes exact; tokens ≈ (we measure bytes, not the tokenizer).")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private func sectionLabel(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Rectangle().fill(hair).frame(height: 1).padding(.bottom, 8)
            Text(t).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(.tertiary)
            Text(sub).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
    }

    private func row(label: String, method: String, bytes: Int, exact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: 11.5, weight: .medium))
                    tag(exact)
                }
                Text(method).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(exact ? "" : "≈")\(byteStr(bytes))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text("≈\(tokenStr(bytes / 4)) tok").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func totalRow(_ label: String, bytes: Int, exact: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("\(byteStr(bytes)) · ≈\(tokenStr(bytes / 4)) tok")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 8)
    }

    private func tag(_ exact: Bool) -> some View {
        Text(exact ? "EXACT" : "≈EST")
            .font(.system(size: 8, weight: .heavy)).tracking(0.3)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(exact ? Color.primary.opacity(0.85) : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(exact ? Color(nsColor: .windowBackgroundColor) : .secondary)
    }

    private func techLabel(_ hook: String) -> String {
        switch hook {
        case "tokopt-bash": return "Bash output trim"
        case "tokopt-read": return "File-read trim"
        case "image-pointer": return "Image → pointer"
        default: return hook
        }
    }

    private func byteStr(_ b: Int) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1_024 { return String(format: "%.0f KB", Double(b) / 1_024) }
        return "\(b) B"
    }
    private func tokenStr(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1_000 { return String(format: "%.0fK", Double(t) / 1_000) }
        return "\(t)"
    }
}
