import AppKit
import Foundation

/// The work Throttle does on its own behalf: the launch re-index and the Research
/// Vault folder ingest. It used to run for minutes at ~200% CPU with nothing on
/// screen. This is the single place that knows what is running, how far along it
/// is, and how to pause or skip it — the Cockpit's BACKGROUND cell and the
/// menu-bar hairline both read it.
///
/// Every number here is measured: fractions come from the jobs' own counters, the
/// ETA is extrapolated from items already finished (and shown with `≈`), and CPU
/// is Throttle's own process time from `getrusage`, never a per-job guess.
@MainActor @Observable
final class BackgroundWork {
    static let shared = BackgroundWork()

    private(set) var jobs: [Job] = []
    /// The launch pass was skipped under memory pressure and is waiting for it
    /// to clear (the design's SKIPPED state).
    private(set) var waitingForMemory = false
    /// Throttle's whole-process CPU, in percent of one core (can exceed 100).
    private(set) var cpuPercent: Double?
    private(set) var menuBarMark: MenuBarMark?
    /// One sentence for VoiceOver on the menu-bar item; updated on events only.
    private(set) var accessibilitySentence: String?

    @ObservationIgnored private var controls: [Kind: BackgroundWorkControl] = [:]
    @ObservationIgnored private var resumers: [Kind: @MainActor () -> Void] = [:]
    @ObservationIgnored private var cpuTimer: Timer?
    @ObservationIgnored private var lastCPUSample: (wall: TimeInterval, cpu: TimeInterval)?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var memoryRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pausedSemanticRoots: [String] = []
    /// A paused index keeps its count on resume (3/9 stays 3/9, not 0/6).
    @ObservationIgnored private var carryOver: Job?

    private init() {
        MemoryPressureMonitor.shared.onPressureRise { [weak self] _ in
            self?.pauseForMemoryPressure()
        }
    }

    // MARK: - Derived (read by the cell and popover, not by the menu bar)

    var isVisible: Bool { !jobs.isEmpty || waitingForMemory }
    var activeJobs: [Job] { jobs.filter(\.isActive) }
    var hasFailures: Bool { jobs.contains { !$0.failures.isEmpty } }
    /// The job whose fraction the strip shows: the index when it runs, else the
    /// first remaining job.
    var headline: Job? { activeJobs.first { $0.kind == .semanticIndex } ?? activeJobs.first ?? jobs.first }

    func job(_ kind: Kind) -> Job? { jobs.first { $0.kind == kind } }

    // MARK: - Semantic index

    /// Launch entry point. Gated exactly as before (opt-in, memory quiet), but a
    /// skip under pressure is now visible and retried when pressure clears.
    func startSemanticIndexAtLaunch() {
        guard SemanticAutoIndexer.isEnabled else { return }
        if memoryIsTight {
            waitingForMemory = true
            announce(String(localized: "Background work skipped: memory pressure. It will retry when memory clears."))
            publishMenuBar()
            scheduleMemoryRetry()
            return
        }
        startSemanticIndex(roots: nil)
    }

    /// `roots == nil` means every Claude Code project (resolved off-main).
    func startSemanticIndex(roots: [String]?) {
        guard job(.semanticIndex)?.isActive != true else { return }
        waitingForMemory = false
        memoryRetryTask?.cancel()
        let control = BackgroundWorkControl()
        controls[.semanticIndex] = control
        resumers[.semanticIndex] = { [weak self] in
            guard let self else { return }
            self.startSemanticIndex(roots: self.pausedSemanticRoots)
        }
        begin(.semanticIndex)
        Task.detached(priority: .utility) {
            let all = roots ?? ProjectsService.listProjects().compactMap { $0.projectPath }
            let summary = SemanticAutoIndexer.run(
                roots: all, enabled: true, memoryQuiet: false,
                embedder: NLEmbeddingProvider(), control: control,
                onEvent: { event in
                    // FIFO onto main: events must arrive in the order they fired.
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        BackgroundWork.shared.apply(event, roots: all)
                    } }
                })
            let remaining = summary.pausedRemaining
            let changed = summary.reposTouched > 0
            DispatchQueue.main.async { MainActor.assumeIsolated {
                BackgroundWork.shared.semanticPassEnded(remaining: remaining, changedAnything: changed)
            } }
        }
    }

    private func apply(_ event: SemanticAutoIndexer.Event, roots: [String]) {
        update(.semanticIndex) { job in
            switch event {
            case .started(let total):
                job.total = job.baseline + total
            case .repoStarted(_, let name):
                job.current = name
            case .repoFinished(let index, let name, let outcome):
                job.done += 1
                switch outcome {
                case .done: break
                case .skipped: job.skippedItems += 1
                case .failed(let reason):
                    job.failures.append(Failure(name: name, reason: reason,
                                                path: roots.indices.contains(index) ? roots[index] : nil))
                    announce(String(localized: "Indexing \(name) failed; the other repos continue."))
                }
            }
        }
    }

    private func semanticPassEnded(remaining: [String], changedAnything: Bool) {
        if !remaining.isEmpty {
            // The loop stopped for a pause; keep the job on screen as paused.
            pausedSemanticRoots = remaining
            update(.semanticIndex) { job in
                if job.phase != .pressurePaused { job.phase = .paused }
                job.current = nil
            }
            return
        }
        // A launch pass that found nothing to (re)embed is the steady state: no
        // DONE card, no announcement — only real work earns eight seconds.
        if !changedAnything, job(.semanticIndex)?.failures.isEmpty != false,
           job(.semanticIndex)?.skippedItems == 0 {
            jobs.removeAll { $0.kind == .semanticIndex }
            controls[.semanticIndex] = nil
            if activeJobs.isEmpty { stopCPUSampling() }
            publishMenuBar()
            return
        }
        finish(.semanticIndex)
    }

    // MARK: - Research Vault ingest

    /// Called by the vault's folder sync for every folder it scans, before any
    /// file is imported. Returns the control the sync must poll between batches.
    /// The job appears only once there is something to import, so an idle
    /// folder-monitor tick never flashes the cell.
    func vaultFolderScanned(files: Int, remainingFolders: Int,
                            resume: @escaping @MainActor () -> Void) -> BackgroundWorkControl {
        if job(.vaultIngest)?.isActive != true {
            controls[.vaultIngest] = BackgroundWorkControl()
            resumers[.vaultIngest] = resume
            begin(.vaultIngest)
        }
        update(.vaultIngest) { job in
            job.total += files
            job.totalIsPartial = remainingFolders > 0
        }
        return controls[.vaultIngest] ?? BackgroundWorkControl()
    }

    func vaultImported(files: Int, current: String) {
        update(.vaultIngest) { job in
            job.done += files
            job.current = current
        }
    }

    func vaultFolderSkipped(_ name: String, files: Int) {
        update(.vaultIngest) { job in
            job.skippedItems += 1
            job.total = max(job.done, job.total - files)   // the rest of it won't run
        }
    }

    func vaultFolderFailed(_ name: String, reason: String) {
        update(.vaultIngest) { job in job.failures.append(Failure(name: name, reason: reason)) }
        announce(String(localized: "Vault folder \(name) could not be read; the other folders continue."))
    }

    /// `paused == true` when the sync stopped because a pause was requested.
    func vaultSyncEnded(paused: Bool) {
        guard job(.vaultIngest) != nil else { return }
        if paused {
            update(.vaultIngest) { job in
                if job.phase != .pressurePaused { job.phase = .paused }
                job.current = nil
            }
            return
        }
        finish(.vaultIngest)
    }

    // MARK: - Actions (the popover's one-action-per-job)

    func skipCurrent(_ kind: Kind) {
        controls[kind]?.requestSkip()
    }

    func pauseAll() {
        for job in activeJobs where job.phase == .running {
            controls[job.kind]?.requestPause()
            update(job.kind) { $0.phase = .pausing }
        }
    }

    func resumeAll() {
        for job in activeJobs where job.phase == .paused || job.phase == .pressurePaused {
            resume(job.kind)
        }
    }

    func runAnyway() {
        waitingForMemory = false
        memoryRetryTask?.cancel()
        startSemanticIndex(roots: nil)
    }

    func retryFailures(_ kind: Kind) {
        guard let failed = job(kind)?.failures, !failed.isEmpty else { return }
        jobs.removeAll { $0.kind == kind }
        switch kind {
        case .semanticIndex: startSemanticIndex(roots: failed.compactMap(\.path))
        case .vaultIngest: resumers[.vaultIngest]?()
        }
    }

    func dismissFinished() {
        jobs.removeAll { !$0.isActive }
        if jobs.isEmpty { stopCPUSampling() }
        publishMenuBar()
    }

    var anyPausable: Bool { activeJobs.contains { $0.phase == .running } }
    var anyResumable: Bool { activeJobs.contains { $0.phase == .paused || $0.phase == .pressurePaused } }

    // MARK: - Lifecycle

    private func begin(_ kind: Kind) {
        collapseTask?.cancel()
        jobs.removeAll { $0.kind == kind || !$0.isActive && $0.failures.isEmpty }
        var fresh = Job(kind: kind)
        if kind == .semanticIndex, let carried = carryOver {
            fresh.done = carried.done
            fresh.baseline = carried.done
            fresh.skippedItems = carried.skippedItems
            fresh.failures = carried.failures
        }
        carryOver = nil
        jobs.append(fresh)
        jobs.sort { $0.kind == .semanticIndex && $1.kind != .semanticIndex }
        startCPUSampling()
        publishMenuBar()
        if activeJobs.count == 1 {
            announce(String(localized: "Background work started: \(kind.title)."))
        }
    }

    private func resume(_ kind: Kind) {
        let resumer = resumers[kind]
        if kind == .semanticIndex { carryOver = job(kind) }
        jobs.removeAll { $0.kind == kind }
        resumer?()
        publishMenuBar()
    }

    private func finish(_ kind: Kind) {
        update(kind) { job in
            job.phase = .finished
            job.current = nil
            job.finishedAt = Date()
        }
        controls[kind] = nil
        guard activeJobs.isEmpty else { return }
        stopCPUSampling()
        if hasFailures {
            announce(String(localized: "Background work finished with errors."))
            publishMenuBar()
            return   // a failure stays until the user retries or dismisses it
        }
        announce(String(localized: "Background work finished."))
        publishMenuBar()
        // DONE: the cell stays 8 s, then collapses (design 1a). Scheduled here,
        // never from a render pass.
        collapseTask?.cancel()
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.activeJobs.isEmpty, !self.hasFailures else { return }
            self.jobs.removeAll()
            self.publishMenuBar()
        }
    }

    private func update(_ kind: Kind, _ body: (inout Job) -> Void) {
        guard let slot = jobs.firstIndex(where: { $0.kind == kind }) else { return }
        var job = jobs[slot]
        body(&job)
        if job != jobs[slot] { jobs[slot] = job }
        publishMenuBar()
    }

}

// Memory pressure, CPU sampling and the menu-bar values: same file so they keep
// private access to the stored state above.
extension BackgroundWork {
    // MARK: - Memory pressure

    private var memoryIsTight: Bool {
        MemoryPressureMonitor.shared.isQuiet || SystemMemoryService.sample().underPressure
    }

    private func pauseForMemoryPressure() {
        let running = activeJobs.filter { $0.phase == .running || $0.phase == .pausing }
        guard !running.isEmpty else { return }
        for job in running {
            controls[job.kind]?.requestPause()
            update(job.kind) { $0.phase = .pressurePaused }
        }
        announce(String(localized: "Background work paused: memory pressure."))
        scheduleMemoryRetry()
    }

    /// Polls once a minute (for at most an hour) and resumes when memory has
    /// cleared. The kernel posts no "back to normal" callback we can hook here.
    private func scheduleMemoryRetry() {
        memoryRetryTask?.cancel()
        memoryRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                guard !self.memoryIsTight else { continue }
                if self.waitingForMemory {
                    self.runAnyway()
                } else {
                    for job in self.activeJobs where job.phase == .pressurePaused { self.resume(job.kind) }
                }
                return
            }
        }
    }

    // MARK: - CPU (Throttle's own process, measured)

    private func startCPUSampling() {
        guard cpuTimer == nil else { return }
        lastCPUSample = ProcessCPU.sample()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { BackgroundWork.shared.tickCPU() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cpuTimer = timer
    }

    private func stopCPUSampling() {
        cpuTimer?.invalidate()
        cpuTimer = nil
        lastCPUSample = nil
        cpuPercent = nil
    }

    private func tickCPU() {
        let now = ProcessCPU.sample()
        defer { lastCPUSample = now }
        guard let last = lastCPUSample, now.wall > last.wall else { return }
        let pct = (now.cpu - last.cpu) / (now.wall - last.wall) * 100
        // Whole-percent resolution: sub-percent jitter would re-render the strip
        // every tick for nothing.
        let rounded = max(0, pct.rounded())
        if cpuPercent != rounded { cpuPercent = rounded }
    }

    // MARK: - Menu bar + VoiceOver

    /// Recomputes the two stored values the menu bar reads. Quantised so a pass
    /// changes the status item's image at most `menuBarSteps` times.
    private func publishMenuBar() {
        let mark: MenuBarMark?
        if let head = activeJobs.first(where: { $0.kind == .semanticIndex }) ?? activeJobs.first {
            mark = head.phase == .pressurePaused
                ? .quiet
                : .progress(Int((head.fraction * Double(Self.menuBarSteps)).rounded(.down)))
        } else if waitingForMemory {
            mark = .quiet
        } else if hasFailures {
            mark = .failed
        } else {
            mark = nil
        }
        if mark != menuBarMark { menuBarMark = mark }

        let sentence = describe()
        if sentence != accessibilitySentence { accessibilitySentence = sentence }
    }
}
