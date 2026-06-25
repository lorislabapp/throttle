import SwiftUI

/// "What's new" — a one-per-version tour of Throttle's optimization features so
/// users discover the cost-cutting tools. Cockpit visual language: flat sections,
/// hairlines, graphite icons, a single accent for the action. Shown automatically
/// after an update; re-openable from the top bar.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private let hair = Color.primary.opacity(0.10)

    private struct Feature: Identifiable {
        let id = UUID(); let icon: String; let title: String; let blurb: String; let now: Bool
    }

    // Curated: the optimizations, newest first. `now` flags this release's additions.
    private let features: [Feature] = [
        .init(icon: "bolt.horizontal", title: "Recoverable Miss Cost",
              blurb: "The audit panel now puts a € figure on cache waste: money spent re-writing a prompt cache that should still have been warm (a busted prefix billed at the 1.25× write rate instead of the 0.10× read rate).", now: true),
        .init(icon: "scope", title: "Spatial skill scoping",
              blurb: "Throttle spots a skill used in only one project but loaded into every session, and offers to move it into that project (reversible) so it stops taxing the rest.", now: true),
        .init(icon: "contextualmenu.and.cursorarrow", title: "Throttle-shaped terminal menu",
              blurb: "Right-click the terminal: Compact context (/compact), paste an image as OCR'd text (skip vision tokens), ask claude to explain/fix/summarize, and pause/resume the session (freeze token burn, no lost state).", now: true),
        .init(icon: "arrow.triangle.2.circlepath", title: "Runaway-loop circuit breaker",
              blurb: "Spots an agent cycling the same action with no file changes — burning tokens toward your 5-hour cap — and lets you pause it.", now: false),
        .init(icon: "gauge.with.dots.needle.33percent", title: "Quiet mode under memory pressure",
              blurb: "When your Mac is swapping hard, Throttle backs off its own background scans so it stops adding to the lag. Automatic.", now: false),
        .init(icon: "puzzlepiece.extension", title: "Dead-skill & MCP audit",
              blurb: "Claude Code setup panel flags loaded MCP servers / skills you haven't used in 30 days — paying schema-token cost for nothing.", now: false),
        .init(icon: "dot.radiowaves.left.and.right", title: "Read firewall + MCP probe",
              blurb: "Detects brute-force whole-file reads and offers a 1-click local-RAG config (snippets, not whole files); probes each MCP server for its real tool + schema cost.", now: false),
        .init(icon: "eurosign.circle", title: "Cost per outcome",
              blurb: "Project Stats shows ≈ cost per commit and per verify-run — honest workflow economics, never a faked pass/fail.", now: false),
        .init(icon: "wand.and.stars", title: "Autopilot + tool-output compression",
              blurb: "Auto-applies the provably-safe optimizations (concise output style, usage statusline), opt-in archives stale memory / dead skills, and compresses verbose command output before Claude sees it. All reversible / fail-open.", now: false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hair).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(features) { f in
                        row(f)
                        Rectangle().fill(hair).frame(height: 1)
                    }
                }
            }
            footer
        }
        .frame(width: 480, height: 540)
        .onAppear { WhatsNewService.markSeen() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("What's new in Throttle").font(.system(size: 13, weight: .semibold))
                Text("Optimizations to cut tokens + protect your cap").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func row(_ f: Feature) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: f.icon).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.title).font(.system(size: 12.5, weight: .medium))
                    if f.now {
                        Text("new").font(.system(size: 8.5, weight: .semibold)).textCase(.lowercase).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 4).padding(.vertical, 1).overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
                    }
                }
                Text(f.blurb).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var footer: some View {
        Text("Find these in the cockpit top bar (stethoscope · chart · puzzle) and the project Stats tab.")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color.primary.opacity(0.03))
    }
}
