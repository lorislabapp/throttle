import AppKit
import SwiftTerm

/// A SwiftTerm terminal that (1) accepts file drops like Terminal.app — turning
/// dropped images into inline `[Image #N]` (or OCR'd text) for `claude` — and
/// (2) sniffs the PTY output stream so the Cockpit can tell when `claude` is
/// blocked on a question, even in a hidden background session.
///
/// Drop behaviour (confirmed against Claude Code):
///  • The drop is fed to the PTY wrapped in a **bracketed paste**
///    (`ESC[200~ … ESC[201~`) whenever the foreground program enabled bracketed
///    paste mode (claude does; so do zsh/bash). That is the signal Claude Code's
///    paste handler uses to run its image-path detection: a recognised image
///    extension is read from disk and shown as `[Image #N]`.
///  • Paths are **backslash-escaped**, NOT single-quoted: Claude Code's detector
///    expects bare escaped paths and does not strip surrounding quotes.
///
/// Output sniffing: `dataReceived` is `open` and SwiftTerm posts it on the main
/// queue (LocalProcess defaults its dispatchQueue to `.main`). We strip ANSI,
/// keep a small rolling tail of visible text, and — after the stream settles —
/// fire `onPrompt` when the tail looks like an interactive question. We never
/// rewrite the stream; we only observe bytes we already render.
final class DroppableTerminalView: LocalProcessTerminalView {

    // MARK: Output-sniffing hooks (assigned by CockpitTab, called on main)
    var onActivity: (@MainActor () -> Void)?
    var onPrompt: (@MainActor (String) -> Void)?
    /// Fired when claude prints a usage/rate-limit message. Date = parsed reset
    /// time if claude stated one, else nil (caller applies a fallback window).
    var onRateLimit: (@MainActor (Date?) -> Void)?
    nonisolated(unsafe) private var lastRateLimitFire = Date.distantPast

    // Detection state — main-thread-confined (LocalProcess posts on .main).
    nonisolated(unsafe) private var tail = ""
    nonisolated(unsafe) private var escState: EscState = .normal
    nonisolated(unsafe) private var detectWork: DispatchWorkItem?
    nonisolated(unsafe) private var lastFired = ""

    // Selection preservation: while the user is dragging a selection, streamed
    // PTY output would scroll the buffer out from under the mouse and clear the
    // selection. We BUFFER incoming bytes during an active drag and flush them on
    // mouse-up, so a selection survives mid-stream. Bounded so a stuck drag can't
    // hoard output forever.
    nonisolated(unsafe) private var selecting = false
    // The user scrolled up to read scrollback — hold new output so it doesn't yank
    // the viewport back to the live bottom. Set on an upward scroll, cleared when
    // they return to the bottom (or hit "jump to live"). Reuses the same buffer.
    nonisolated(unsafe) private var scrolledUpByUser = false
    // A selection still EXISTS after the drag ends (mouse released). Keep holding
    // output until the user deselects (a fresh click) — otherwise the flush on
    // mouse-up would redraw and wipe the selection the user just made mid-stream.
    nonisolated(unsafe) private var holdForSelection = false
    nonisolated(unsafe) private var pendingChunks: [[UInt8]] = []
    nonisolated(unsafe) private var pendingBytes = 0
    nonisolated(unsafe) private var selectionMonitor: Any?
    private static let pendingCap = 2 * 1024 * 1024   // give up holding past 2 MB

    private enum EscState { case normal, esc, csi, osc, oscEsc }

    override init(frame: CGRect) {
        super.init(frame: frame)
        enableFileDrops()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        enableFileDrops()
    }

    // MARK: - Input activity

    /// User input (keystrokes/paste) sent to the PTY counts as activity too, so
    /// the session reads as "working" the instant you hit Enter — through claude's
    /// pre-first-token think gap — instead of flickering to idle. `send(source:)`
    /// is SwiftTerm's open hook for terminal→process bytes.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            onActivity?()
            // Typing/pasting means the user wants the LIVE prompt. Drop any output
            // hold (a lingering selection, scrolled-up, or a missed mouse-up) and
            // flush — otherwise the echoed input is swallowed by the buffer and the
            // session looks frozen ("I type and nothing happens").
            if selecting || holdForSelection || scrolledUpByUser {
                selecting = false; holdForSelection = false; scrolledUpByUser = false
                flushPending()
            }
        }
        super.send(source: source, data: data)
    }

    // MARK: - Output sniffing

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Copy the bytes out first (Sendable) for the main hop. ALL rendering +
        // detection-state mutation happens inside the main-confined block, so
        // `tail`/`escState`/`selecting` are only ever touched on the main thread.
        let bytes = Array(slice)
        let handle: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // Self-heal: if the scroll-up flag is stuck (e.g. the user returned to
            // the bottom via the scrollbar, which fires no scrollWheel event) but
            // we're actually at the live bottom, drop it so output isn't held forever.
            if self.scrolledUpByUser && self.atLiveBottom { self.scrolledUpByUser = false }
            // Hold output while the user is dragging a selection, a selection sits
            // on screen, OR they've scrolled up — rendering would yank the viewport
            // or wipe the selection. Bounded — past the cap we render live.
            if (self.selecting || self.holdForSelection || self.scrolledUpByUser) && self.pendingBytes < Self.pendingCap {
                self.pendingChunks.append(bytes)
                self.pendingBytes += bytes.count
                return
            }
            self.renderAndSniff(bytes)
        }
        if Thread.isMainThread { MainActor.assumeIsolated(handle) }
        else { DispatchQueue.main.async { MainActor.assumeIsolated(handle) } }
    }

    /// Render bytes to the terminal and run the prompt/rate-limit sniffer.
    @MainActor private func renderAndSniff(_ bytes: [UInt8]) {
        super.dataReceived(slice: bytes[...])
        appendStripped(bytes[...])
        onActivity?()
        scheduleDetect()
    }

    /// Replay everything we buffered, in order (lands the viewport at live).
    @MainActor private func flushPending() {
        guard !pendingChunks.isEmpty else { return }
        let chunks = pendingChunks
        pendingChunks.removeAll(); pendingBytes = 0
        for c in chunks { renderAndSniff(c) }
    }

    /// Flush only when nothing is holding output back — no active drag, no live
    /// selection sitting on screen, and not scrolled up.
    @MainActor private func flushIfReady() {
        if !selecting && !holdForSelection && !scrolledUpByUser { flushPending() }
    }

    private func hasSelection() -> Bool { (getSelection()?.isEmpty == false) }

    /// True once the scrollback is parked at (or within a hair of) the live bottom.
    private var atLiveBottom: Bool { scrollPosition >= 0.999 }

    /// Track selection drags AND scroll-up via a local event monitor (mouseDragged/
    /// scrollWheel aren't `open` on SwiftTerm's view, so we observe instead of
    /// override). Holds output while reading up; flushes on return to the bottom.
    private func installSelectionMonitor() {
        selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                switch event.type {
                case .leftMouseDown:
                    // A fresh click abandons any prior selection → stop holding for
                    // it and let the held output catch up (a drag may re-hold next).
                    self.holdForSelection = false
                    self.flushIfReady()
                case .leftMouseDragged:
                    if self.eventIsOverSelf(event) { self.selecting = true }
                case .leftMouseUp:
                    self.selecting = false
                    // Keep holding if a selection now sits on screen; flush if not.
                    self.holdForSelection = self.eventIsOverSelf(event) && self.hasSelection()
                    self.flushIfReady()
                case .scrollWheel:
                    if self.eventIsOverSelf(event), event.deltaY > 0 { self.scrolledUpByUser = true }
                    // After SwiftTerm applies the scroll, re-evaluate: back at the
                    // bottom → stop holding and flush what streamed while reading.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if self.atLiveBottom { self.scrolledUpByUser = false; self.flushIfReady() }
                        }
                    }
                default: break
                }
            }
            return event   // never consume — let SwiftTerm handle the gesture
        }
    }

    private func eventIsOverSelf(_ event: NSEvent) -> Bool {
        guard let win = window, event.window === win else { return false }
        return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Strip ANSI/OSC escapes incrementally (carrying state across chunks) and
    /// append the visible text to a capped rolling tail.
    private func appendStripped(_ bytes: ArraySlice<UInt8>) {
        var visible: [UInt8] = []
        visible.reserveCapacity(bytes.count)
        for b in bytes {
            switch escState {
            case .normal:
                if b == 0x1B { escState = .esc }
                else if b == 0x07 { /* BEL */ }
                else if b == 0x08 { if !visible.isEmpty { visible.removeLast() } }  // backspace
                else if b >= 0x20 || b == 0x0A || b == 0x09 { visible.append(b) }
            case .esc:
                if b == UInt8(ascii: "[") { escState = .csi }
                else if b == UInt8(ascii: "]") { escState = .osc }
                else { escState = .normal }                                       // 2-byte/other escape
            case .csi:
                if (0x40...0x7E).contains(b) { escState = .normal }               // final byte
            case .osc:
                if b == 0x07 { escState = .normal }                               // BEL terminates OSC
                else if b == 0x1B { escState = .oscEsc }
            case .oscEsc:
                escState = (b == UInt8(ascii: "\\")) ? .normal : .osc             // ST = ESC \
            }
        }
        guard !visible.isEmpty else { return }
        // Decode as UTF-8 so multi-byte glyphs (❯, accents) survive intact.
        tail += String(decoding: visible, as: UTF8.self)
        if tail.count > 1400 { tail = String(tail.suffix(1200)) }
    }

    /// Debounce: only inspect once the stream has been quiet briefly — that's
    /// when claude has finished printing the prompt and is waiting on stdin.
    private func scheduleDetect() {
        detectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.detect() }
        }
        detectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func detect() {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let recent = lines.suffix(8)
        let hay = recent.joined(separator: "\n")
        let lower = hay.lowercased()

        // Rate-limit: claude prints "Claude usage limit reached. Your limit will
        // reset at 11pm." (5h or weekly cap) when the account is throttled. Catch
        // it so the cockpit can flag WHICH session is blocked + when it frees up.
        // Debounced (claude redraws the banner) so we fire at most once / 30s.
        if lower.contains("usage limit reached") || lower.contains("limit will reset")
            || (lower.contains("limit reached") && lower.contains("reset")) {
            if Date().timeIntervalSince(lastRateLimitFire) > 30 {
                lastRateLimitFire = Date()
                onRateLimit?(Self.parseResetTime(from: hay))
            }
        }

        // ONLY fire on a genuine interactive prompt — the thing that actually
        // blocks claude on stdin. Two robust shapes:
        //  • a numbered selection menu: "❯" plus at least TWO options (1. + 2.)
        //    — claude's permission / trust / plan dialogs always have ≥2.
        //  • an explicit yes/no confirmation.
        // Loose prose triggers ("do you want", a stray "?") are deliberately
        // gone: they fired on claude's own normal output.
        let hasMenu = hay.contains("❯") && lower.contains("1.") && lower.contains("2.")
        let hasYN = lower.contains("(y/n)") || lower.contains("[y/n]")
        guard hasMenu || hasYN else { return }

        let q = questionText(from: recent)
        guard q != lastFired else { return }
        lastFired = q
        onPrompt?(q)
    }

    /// The question is normally the line just above the options, ending in "?".
    /// Our ANSI strip can lose spaces when claude redraws, so guard against
    /// mangled output (one giant run-on token) and fall back to a clean label.
    private func questionText(from lines: ArraySlice<String>) -> String {
        let q = lines.last { $0.contains("?") && !$0.contains("1.") && !$0.contains("❯") }
        var cleaned = (q ?? "").replacingOccurrences(of: "❯", with: "").trimmingCharacters(in: .whitespaces)
        // M11: collapse internal whitespace so a repainted prompt (claude redraws
        // the same question with different spacing) normalizes to the SAME string
        // — `lastFired` then dedupes it instead of firing a duplicate notification.
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let longestRun = cleaned.split(separator: " ").map(\.count).max() ?? 0
        if cleaned.isEmpty || longestRun > 28 { return "Waiting for your choice" }
        return cleaned.count > 140 ? String(cleaned.prefix(137)) + "…" : cleaned
    }

    /// Parse claude's "reset at 11pm" / "resets 3:30pm" into the next such clock
    /// time (today, or tomorrow if already past). nil if no time is stated.
    static func parseResetTime(from text: String) -> Date? {
        guard let m = try? NSRegularExpression(pattern: "(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)", options: .caseInsensitive),
              let r = m.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hr = Range(r.range(at: 1), in: text).flatMap({ Int(text[$0]) }) else { return nil }
        let minute = Range(r.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let isPM = Range(r.range(at: 3), in: text).map { text[$0].lowercased() == "pm" } ?? false
        var hour24 = hr % 12
        if isPM { hour24 += 12 }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour24; comps.minute = minute
        guard var date = cal.date(from: comps) else { return nil }
        if date <= Date() { date = cal.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    // MARK: - Right-click context menu

    /// SwiftTerm ships no contextual menu, so right-click did nothing. Provide
    /// the expected Copy / Paste / Select All / Clear, plus — when there's a
    /// selection — one-click "ask claude" prompts that paste into the session.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let sel = getSelection()
        let hasSel = (sel?.isEmpty == false)

        ctxItem(menu, "Copy", enabled: hasSel) { [weak self] in self?.copy(NSNull()) }
        ctxItem(menu, "Paste", enabled: true) { [weak self] in self?.paste(NSNull()) }
        ctxItem(menu, "Select All", enabled: true) { [weak self] in self?.selectAll(nil) }
        menu.addItem(.separator())
        ctxItem(menu, "Clear", enabled: true) { [weak self] in self?.send(txt: "\u{0c}") }

        menu.addItem(.separator())
        ctxItem(menu, "Paste latest Xcode build errors", enabled: true) { [weak self] in
            self?.pasteXcodeErrors()
        }

        if hasSel, let s = sel {
            menu.addItem(.separator())
            ctxItem(menu, "Ask claude to summarize", enabled: true) { [weak self] in
                self?.paste("Summarize this:\n\n\(s)\n") }
            ctxItem(menu, "Ask claude to explain", enabled: true) { [weak self] in
                self?.paste("Explain this:\n\n\(s)\n") }
        }
        return menu
    }

    /// Pull distilled errors from the newest Xcode build (off-main — runs
    /// `xcresulttool`) and paste them for claude to fix. No-op chatter if none.
    private func pasteXcodeErrors() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = XcodeBuildErrorsService.distilledErrors(projectHint: nil)
            DispatchQueue.main.async {
                guard let self else { return }
                if let text { self.paste(text + "\n") }
                else { NSSound.beep() }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    private func ctxItem(_ menu: NSMenu, _ title: String, enabled: Bool, _ run: @escaping () -> Void) {
        let it = NSMenuItem(title: title, action: #selector(dropMenuChose(_:)), keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled
        it.representedObject = BlockBox(run)
        menu.addItem(it)
    }

    // MARK: - Timeline navigation

    /// Scroll the viewport to the previous (older) / next (newer) conversation
    /// turn — a line whose first glyph is a claude bullet (⏺ / ●) or a user
    /// prompt (> / ❯). Steps one line at a time using only public SwiftTerm APIs
    /// (scrollUp/Down + getCharData on the top visible row).
    func scrollToTurn(older: Bool) {
        // Programmatic scroll (no scrollWheel event), so set the hold flag from the
        // final position ourselves — otherwise live output yanks away from the turn
        // the user just navigated to.
        defer { scrolledUpByUser = !atLiveBottom; if atLiveBottom { flushIfReady() } }
        let term = getTerminal()
        var steps = 0
        while steps < 8000 {
            steps += 1
            let pos = scrollPosition
            if older && pos <= 0 { break }
            if !older && pos >= 1 { break }
            if older { scrollUp(lines: 1) } else { scrollDown(lines: 1) }
            if topLineIsTurnMarker(term) { return }
        }
    }

    private func topLineIsTurnMarker(_ term: Terminal) -> Bool {
        var s = ""
        for col in 0..<min(term.cols, 8) {
            if let cd = term.getCharData(col: col, row: 0) { s.append(cd.getCharacter()) }
        }
        guard let first = s.trimmingCharacters(in: .whitespaces).first else { return false }
        return first == "⏺" || first == "●" || first == ">" || first == "❯"
    }

    /// Jump back to the live bottom of the scrollback — stop holding output and
    /// replay anything that streamed while the user was reading up.
    func scrollToLive() {
        scrolledUpByUser = false
        holdForSelection = false
        flushPending()
        scroll(toPosition: 1)
    }

    // MARK: - File drops

    private func enableFileDrops() {
        registerForDraggedTypes(Array(Set(registeredDraggedTypes + [.fileURL])))
        setAccessibilityLabel("Claude terminal")
        setAccessibilityRole(.textArea)
        installSelectionMonitor()
    }

    deinit { if let m = selectionMonitor { NSEvent.removeMonitor(m) } }

    private func containsFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        containsFileURLs(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        containsFileURLs(sender) ? .copy : super.draggingUpdated(sender)
    }

    /// UserDefaults flag: drop images as locally-OCR'd TEXT (cheap) instead of
    /// as `[Image #N]` (costly vision tokens). Used as the default only on the
    /// **Option-held** fast path; otherwise a drop menu lets the user choose.
    static let ocrDefaultsKey = "cockpitDropImagesAsText"

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        window?.makeFirstResponder(self)

        let hasImage = urls.contains { ImageTextExtractor.isImage($0) }

        // No image, or Option-held fast path → no menu (keep the power-user bypass).
        if !hasImage {
            paste(urls.map { Self.terminalEscape($0.path) }.joined(separator: " "), trailingSpace: true)
            return true
        }
        if NSEvent.modifierFlags.contains(.option) {
            performDrop(urls, ocr: UserDefaults.standard.bool(forKey: Self.ocrDefaultsKey))
            return true
        }

        // Pop the choice menu IMMEDIATELY. Image-token estimate is read from
        // the file header (no decode), so it's instant; OCR runs only if the
        // user actually picks "OCR → text", off-main, in performDrop.
        let point = convert(sender.draggingLocation, from: nil)
        let imageTok = urls.filter { ImageTextExtractor.isImage($0) }
            .reduce(0) { $0 + ImageTextExtractor.imageTokenEstimate($1) }
        presentDropMenu(urls: urls, at: point, imageTok: imageTok)
        return true
    }

    /// Boxed closure so a single @objc action can dispatch either menu choice.
    private final class BlockBox { let run: () -> Void; init(_ r: @escaping () -> Void) { self.run = r } }
    @objc private func dropMenuChose(_ sender: NSMenuItem) { (sender.representedObject as? BlockBox)?.run() }

    private func presentDropMenu(urls: [URL], at point: NSPoint, imageTok: Int) {
        let menu = NSMenu()
        menu.autoenablesItems = false   // we set isEnabled ourselves; AppKit's
                                        // auto-enable disables items popped outside an event.
        let header = NSMenuItem(title: "Dropped image — choose how to send", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let attach = NSMenuItem(title: "Attach image  ·  ≈\(Self.fmt(imageTok)) vision tok",
                                action: #selector(dropMenuChose(_:)), keyEquivalent: "")
        attach.target = self
        attach.isEnabled = true
        attach.representedObject = BlockBox { [weak self] in self?.performDrop(urls, ocr: false) }
        menu.addItem(attach)

        let ocr = NSMenuItem(title: "OCR → text (local)  ·  saves ≈\(Self.fmt(imageTok)) tok",
                             action: #selector(dropMenuChose(_:)), keyEquivalent: "")
        ocr.target = self
        ocr.isEnabled = true
        ocr.representedObject = BlockBox { [weak self] in self?.performDrop(urls, ocr: true) }
        menu.addItem(ocr)

        menu.popUp(positioning: nil, at: point, in: self)
    }

    /// Commit the drop. `ocr=true` pastes recognised text for images (paths for
    /// non-images); `ocr=false` pastes escaped paths (claude → `[Image #N]`).
    /// OCR is synchronous and can take 100s of ms — run it off-main, then paste.
    private func performDrop(_ urls: [URL], ocr: Bool) {
        guard ocr else {
            paste(urls.map { Self.terminalEscape($0.path) }.joined(separator: " "), trailingSpace: true)
            window?.makeFirstResponder(self)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pieces: [String] = urls.map { u in
                if ImageTextExtractor.isImage(u), let t = ImageTextExtractor.extractText(from: u) {
                    return "[image: \(u.lastPathComponent)]\n\(t)"
                }
                return Self.terminalEscape(u.path)
            }
            let joined = pieces.joined(separator: "\n\n")
            DispatchQueue.main.async {
                self?.paste(joined)
                self?.window?.makeFirstResponder(self)
            }
        }
    }

    private static func fmt(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    /// Feed text to the PTY as a bracketed paste when the foreground program
    /// supports it (claude does), else raw bytes — never a literal "[200~".
    private func paste(_ text: String, trailingSpace: Bool = false) {
        if getTerminal().bracketedPasteMode {
            send(txt: "\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            send(txt: text + (trailingSpace ? " " : ""))
        }
    }

    /// Backslash-escape shell/Claude-significant characters, matching how
    /// Terminal.app & Finder escape paths on drag.
    static func terminalEscape(_ path: String) -> String {
        let special: Set<Character> = [
            " ", "\t", "\"", "'", "\\", "(", ")", "[", "]", "{", "}",
            "<", ">", "|", ";", "&", "$", "`", "*", "?", "!", "#", "~",
        ]
        var out = ""
        out.reserveCapacity(path.count + 8)
        for ch in path {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
