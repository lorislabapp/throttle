import SwiftUI

/// Where the golden set is actually built.
///
/// Shadow replay produces cases; nothing about a case is evidence until a human
/// decides whether the pipeline's verdict was earned. That decision cannot be
/// delegated to another model: benchmarks of LLM judges on evidence-verification
/// tasks report accuracies below 55% even for the strongest judges, which is why
/// the bound in the dashboard counts only what a person adjudicated.
///
/// One case at a time, oldest first. Judging in ledger order keeps the sample
/// chronological instead of letting the interesting-looking cases be picked out.
struct AdjudicationSheet: View {
    let onClose: () -> Void

    @State private var pending: [ShadowReplayService.Entry] = []
    @State private var index = 0
    @State private var note = ""
    @State private var stage: ShadowReplayService.Stage = .exploratory

    private let hair = Color.primary.opacity(0.10)

    private var current: ShadowReplayService.Entry? {
        index < pending.count ? pending[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(hair)
            if let entry = current {
                ScrollView { caseBody(entry).padding(16) }
                Divider().overlay(hair)
                actions(entry)
            } else {
                emptyState
            }
        }
        .frame(width: 620, height: 560)
        .background(.background)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adjudicate replay cases").font(.system(size: 13, weight: .semibold))
                Text(pending.isEmpty
                     ? "Nothing waiting"
                     : "\(index + 1) of \(pending.count) waiting")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No cases waiting").font(.system(size: 13, weight: .medium))
            Text("Run a shadow replay from the dashboard to produce cases. Each one stays unproven until you judge it here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func caseBody(_ entry: ShadowReplayService.Entry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                field("PIPELINE", entry.status.uppercased())
                field("KIND", entry.kind)
                if let project = entry.project { field("PROJECT", project) }
                if let backend = entry.backend { field("BACKEND", backend) }
            }
            // The pipeline's own reason is shown, not hidden: the judgement is
            // about whether that reasoning holds, and withholding it would make
            // the task harder without making it more honest.
            section("Pipeline reason", entry.reason)
            if let ask = entry.askExcerpt { section("The request", ask, mono: true) }
            if let output = entry.output { section("What the local model returned", output, mono: true) }
            if let evidence = entry.evidence, !evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    label("Quotes it offered as proof")
                    Text("Each was found byte-for-byte in the source. That proves it came from there — not that it supports the answer, nor that nothing contradicting it was left out.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, quote in
                        Text("“\(quote)”")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                    }
                }
            }
        }
    }

    private func actions(_ entry: ShadowReplayService.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Why (optional — the failure mode is what tunes the prompt)", text: $note)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Picker("", selection: $stage) {
                Text("Exploratory").tag(ShadowReplayService.Stage.exploratory)
                Text("Certification").tag(ShadowReplayService.Stage.certification)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(stage == .certification
                 ? "Frozen: counts toward the bound, and must not have been used to tune the prompt or validator."
                 : "Exploratory: used to find failure modes and tune the pipeline. Never counts toward the bound.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Verdict was right") { judge(entry, verdict: entry.status) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Should have been review") { judge(entry, verdict: "review_required") }
                    .controlSize(.small)
                Button("Should have escalated") { judge(entry, verdict: "escalate") }
                    .controlSize(.small)
                Spacer()
                Button("Skip") { advance() }.controlSize(.small)
            }
        }
        .padding(16)
    }

    private func judge(_ entry: ShadowReplayService.Entry, verdict: String) {
        ShadowReplayService.adjudicate(entryID: entry.id, verdict: verdict,
                                       stage: stage, note: note)
        advance()
    }

    private func advance() {
        note = ""
        index += 1
        if index >= pending.count { reload() }
    }

    private func reload() {
        pending = ShadowReplayService.pendingAdjudication()
        index = 0
    }

    // MARK: - Bits

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            .textCase(.uppercase).tracking(0.6)
    }

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(name)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func section(_ name: String, _ body: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(name)
            Text(body)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
