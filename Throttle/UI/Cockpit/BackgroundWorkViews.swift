import SwiftUI

// Design 1a "Instrument" (Claude Design, Background Work.dc.html): background work
// is a third cell of the Cockpit's global strip, and its popover speaks the
// meter's own row language. Graphite throughout — this is not cap pressure, so
// failed and skipped change glyph, weight and words, never hue. Accent only on
// the actions. No Canvas, no shadow, no numeric content transition (macOS 26.5).

/// BACKGROUND · 2 JOBS — the strip cell. Collapses when nothing runs.
struct BackgroundWorkCell: View {
    @State private var work = BackgroundWork.shared
    @State private var showDetail = false

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        Button { showDetail.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                header
                figures
                BackgroundBar(fill: fill, hatched: hatched, failedTail: failedTail)
                    .frame(width: 168, height: 4)
            }
            .padding(.horizontal, 15).padding(.vertical, 9)
            .frame(minWidth: 236, maxHeight: .infinity, alignment: .leading)
            .background(showDetail ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            BackgroundWorkPopover(work: work)
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityValue(showDetail ? String(localized: "expanded") : "")
    }

    private var accessibilityText: String {
        let sentence: String = work.describe() ?? String(localized: "Background work")
        return sentence + " " + String(localized: "Show details.")
    }

    // MARK: Parts

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            label(headerText)
            if quiet {
                Text("quiet").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(hair, lineWidth: 1))
            }
        }
    }

    private var headerText: String {
        if quiet { return "BACKGROUND" }
        let active = work.activeJobs.count
        if active > 0 { return active == 1 ? "BACKGROUND · 1 JOB" : "BACKGROUND · \(active) JOBS" }
        let failed = work.jobs.reduce(0) { $0 + $1.failures.count }
        return failed > 0 ? "BACKGROUND · \(failed) FAILED" : "BACKGROUND · DONE"
    }

    @ViewBuilder private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(fractionText).font(.system(size: 16, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(quiet ? .tertiary : .primary)
                if let unit = work.headline?.kind.unit, work.headline?.phase != .finished || quiet {
                    Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 3)
                }
            }
            Text(detailText).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var quiet: Bool {
        work.waitingForMemory || work.headline?.phase == .pressurePaused
    }

    private var fractionText: String {
        guard let head = work.headline else { return "—" }
        if work.waitingForMemory && head.phase == .finished { return "—" }
        return "\(head.done)/\(head.total)\(head.totalIsPartial ? "+" : "")"
    }

    private var detailText: String {
        if work.waitingForMemory {
            return String(localized: "skipped · memory pressure · retries when clear")
        }
        guard let head = work.headline else { return "" }
        switch head.phase {
        case .pressurePaused:
            return String(localized: "paused · memory pressure · resumes when clear")
        case .pausing:
            return String(localized: "Pausing…")
        case .paused:
            return String(localized: "Paused")
        case .running:
            var parts = [head.kind == .semanticIndex ? String(localized: "Indexing") : String(localized: "Ingesting")]
            if let eta = head.etaSeconds() {
                parts.append(String(localized: "≈\(BackgroundWork.minutes(eta)) left"))
            }
            if let cpu = work.cpuPercent { parts.append("\(Int(cpu))% CPU") }
            return parts.joined(separator: " · ")
        case .finished:
            return finishedSummary
        }
    }

    /// "indexed · 120 files ingested · 12 min" or "indexed · nimo-ios failed · file too large".
    private var finishedSummary: String {
        var parts: [String] = []
        if let index = work.job(.semanticIndex) {
            if let failure = index.failures.first {
                parts.append(String(localized: "indexed · \(failure.name) failed · \(failure.reason)"))
            } else {
                parts.append(String(localized: "indexed"))
            }
        }
        if let vault = work.job(.vaultIngest) {
            parts.append(String(localized: "\(vault.done) files ingested"))
        }
        let starts = work.jobs.map(\.startedAt)
        let ends = work.jobs.compactMap(\.finishedAt)
        if let first = starts.min(), let last = ends.max() {
            parts.append(BackgroundWork.minutes(last.timeIntervalSince(first)))
        }
        return parts.joined(separator: " · ")
    }

    private var fill: Double {
        guard let head = work.headline else { return 0 }
        if head.phase == .finished && head.failures.isEmpty { return 1 }
        return head.fraction
    }
    private var hatched: Bool { quiet }
    private var failedTail: Double {
        guard let head = work.headline, head.phase == .finished, head.total > 0 else { return 0 }
        return Double(head.failures.count) / Double(head.total)
    }

    private func label(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(.system(size: 8.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

/// The detail: one row per job, one action per row.
struct BackgroundWorkPopover: View {
    let work: BackgroundWork
    private let hair = Color.primary.opacity(0.09)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text("Background work").font(.system(size: 13, weight: .semibold))
                Text("low priority").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                Spacer(minLength: 0)
                if work.anyPausable {
                    action("Pause all") { work.pauseAll() }
                } else if work.anyResumable {
                    action("Resume all") { work.resumeAll() }
                } else if !work.activeJobs.isEmpty {
                    // Only pausing jobs left: nothing to press until they stop.
                    EmptyView()
                } else if !work.jobs.isEmpty {
                    action("Dismiss") { work.dismissFinished() }
                }
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)

            Text(cpuLine).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                .padding(.horizontal, 16).padding(.bottom, 11)

            rule
            if work.waitingForMemory && work.job(.semanticIndex) == nil {
                waitingRow
                rule
            }
            ForEach(work.jobs) { job in
                JobRow(job: job, work: work)
                rule
            }

            Text("Semantic index runs at launch · change it in Settings → General")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 11)
        }
        .frame(width: 340)
    }

    private var rule: some View {
        Rectangle().fill(hair).frame(height: 1).padding(.horizontal, 16)
    }

    /// Throttle's own process CPU. Per-job CPU is not measurable (both jobs
    /// share the process), so the design's per-row CPU is deliberately absent.
    private var cpuLine: String {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard let cpu = work.cpuPercent else {
            return String(localized: "Backs off under memory pressure")
        }
        let used = String(format: "%.1f", cpu / 100)
        return String(localized:
            "\(Int(cpu))% Throttle CPU · \(used) of \(cores) cores · backs off under memory pressure")
    }

    private var waitingRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(BackgroundWork.Kind.semanticIndex.title).font(.system(size: 12.5, weight: .semibold))
                Text(BackgroundWork.Kind.semanticIndex.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("—").font(.system(size: 16)).foregroundStyle(.tertiary)
            }
            BackgroundBar(fill: 0, hatched: true, failedTail: 0).frame(height: 6)
            HStack {
                Text("Skipped · memory pressure · retries when clear")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                action("Run anyway ›") { work.runAnyway() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func action(_ title: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(minHeight: 22)
    }
}

private struct JobRow: View {
    let job: BackgroundWork.Job
    let work: BackgroundWork

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(job.kind.title).font(.system(size: 12.5, weight: .semibold))
                Text(job.kind.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if job.total > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(Int((job.fraction * 100).rounded()))")
                            .font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit()
                        Text("%").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").font(.system(size: 16)).foregroundStyle(.tertiary)
                }
            }
            BackgroundBar(fill: job.fraction, hatched: job.phase == .pressurePaused,
                          failedTail: job.phase == .finished && job.total > 0
                            ? Double(job.failures.count) / Double(job.total) : 0,
                          tone: Color.primary.opacity(0.45))
                .frame(height: 6)
            Text(meta).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            if let failure = job.failures.first, job.phase == .finished {
                Text("\(failure.name): \(failure.reason)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let act = rowAction {
                HStack {
                    Spacer(minLength: 0)
                    Button(act.title, action: act.run).buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.accentColor)
                        .frame(minHeight: 22)
                        .accessibilityLabel(act.a11y)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "3/9 repos · now nimo-ios · ≈4 min left"
    private var meta: String {
        var parts = ["\(job.done)/\(job.total)\(job.totalIsPartial ? "+" : "") \(job.kind.unit)"]
        switch job.phase {
        case .running:
            if let now = job.current { parts.append(String(localized: "now \(now)")) }
            if let eta = job.etaSeconds() { parts.append(String(localized: "≈\(BackgroundWork.minutes(eta)) left")) }
        case .pausing: parts.append(String(localized: "pausing after this file"))
        case .paused: parts.append(String(localized: "paused"))
        case .pressurePaused: parts.append(String(localized: "paused · memory pressure · resumes when clear"))
        case .finished:
            if job.skippedItems > 0 { parts.append(String(localized: "\(job.skippedItems) skipped")) }
            parts.append(job.failures.isEmpty ? String(localized: "done")
                                              : String(localized: "\(job.failures.count) failed"))
        }
        return parts.joined(separator: " · ")
    }

    private struct RowAction {
        let title: LocalizedStringKey
        let a11y: String
        let run: () -> Void
    }

    private var rowAction: RowAction? {
        switch job.phase {
        case .running:
            guard let now = job.current else { return nil }
            return job.kind == .semanticIndex
                ? RowAction(title: "Skip this repo ›", a11y: String(localized: "Skip this repo, \(now)")) {
                    work.skipCurrent(.semanticIndex) }
                : RowAction(title: "Skip this folder ›", a11y: String(localized: "Skip the current folder")) {
                    work.skipCurrent(.vaultIngest) }
        case .paused:
            return RowAction(title: "Resume ›", a11y: String(localized: "Resume \(job.kind.title)")) {
                work.resumeAll() }
        case .pressurePaused:
            return RowAction(title: "Run anyway ›", a11y: String(localized: "Run \(job.kind.title) anyway")) {
                work.resumeAll() }
        case .finished where !job.failures.isEmpty:
            return RowAction(title: "Retry ›", a11y: String(localized: "Retry failed items")) {
                work.retryFailures(job.kind) }
        case .pausing, .finished:
            return nil
        }
    }
}

/// Determinate bar in the strip's language: graphite fill on the track; a hatched
/// fill for "waiting on memory" and a hatched tail for failed items. Hand-rolled
/// with Path (no Canvas) per the macOS 26.5 guardrails.
struct BackgroundBar: View {
    var fill: Double
    var hatched: Bool
    var failedTail: Double
    var tone: Color = .secondary

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if hatched {
                    Hatch().stroke(Color.secondary, lineWidth: 1.5)
                        .frame(width: max(0, width * min(1, fill)))
                        .clipShape(Capsule())
                } else if fill > 0 {
                    Capsule().fill(tone).frame(width: max(2, width * min(1, fill)))
                }
                if failedTail > 0 {
                    Hatch().stroke(Color.primary, lineWidth: 1.5)
                        .frame(width: width * min(1, failedTail))
                        .offset(x: width * (1 - min(1, failedTail)))
                }
            }
            .frame(height: height)
            .clipShape(Capsule())
        }
    }

    /// -45° stripes every 4 pt.
    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var start = rect.minX - rect.height
            while start < rect.maxX {
                path.move(to: CGPoint(x: start, y: rect.maxY))
                path.addLine(to: CGPoint(x: start + rect.height, y: rect.minY))
                start += 4
            }
            return path
        }
    }
}
