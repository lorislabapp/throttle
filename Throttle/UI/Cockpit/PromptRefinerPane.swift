import AppKit
import SwiftUI

/// Direction 1c "Takeover": the refiner is a stack of full-column focus screens,
/// not panels sharing a 280pt column. One screen owns the column at a time, so a
/// 15-line draft never scrolls and the terminal is never covered.
struct PromptRefinerPane: View {
    @State private var model = PromptRefinerModel.shared
    @State private var cockpit = MultiCockpitModel.shared
    @State private var task: Task<Void, Never>?
    @State private var startedAt = Date()
    @State private var now = Date()
    @State private var copied = false
    @State private var whyExpanded = false

    private let hair = Color.primary.opacity(0.10)
    private let accentText = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1.0)
    private let accentFill = Color(red: 0.0, green: 0x71 / 255, blue: 0xE3 / 255)
    private let warn = Color(red: 1.0, green: 0x9F / 255, blue: 0x0A / 255)

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.screen {
            case .home:            home
            case .compose:         compose
            case .loading:         loading
            case .error(let msg):  errorScreen(msg)
            case .result, .applied: result
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(tick) { now = $0 }
        .onDisappear { task?.cancel() }
    }

    // MARK: - Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                dl("TARGET")
                Picker("", selection: $model.mode) {
                    ForEach(RefinerMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.mode.help)

                Button {
                    model.beginCompose()
                } label: {
                    Text("New draft")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(accentFill.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(accentText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                }
                .buttonStyle(.plain)
                .help("Opens a full-column composer — the terminal stays visible")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Rectangle().fill(hair).frame(height: 1)

            if model.history.isEmpty {
                Text("Nothing refined yet. A draft you refine shows up here, ready to reopen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                dl("HISTORY").padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            Button { model.reopen(entry) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(entry.mode.label) · \(PromptRefinerService.metrics(entry.proposed).lines) ln")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Reopen this refinement as a new draft")
                            Rectangle().fill(hair).frame(height: 1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Drafting takes the whole column. Your terminal is never covered.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Compose

    private var compose: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar(title: "\(model.mode.label) · DRAFT") { model.screen = .home }
            TextEditor(text: $model.draft)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                .padding(.horizontal, 14).padding(.top, 12)
                .frame(maxHeight: .infinity)

            HStack {
                Text(metricsLabel(model.draft))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { startRefine(nudge: nil) } label: {
                    Text("Refine ⌘⏎")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(accentFill, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("One call to the refiner model — the cost is shown before you apply")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Loading

    private var loading: some View {
        VStack(spacing: 10) {
            Spacer()
            ForEach([0.92, 0.78, 0.85], id: \.self) { w in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 240 * w, height: 9)
            }
            Text("\(model.proposal?.provider ?? "refining") · \(Int(now.timeIntervalSince(startedAt)))s")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            Button("Cancel") {
                task?.cancel()
                model.screen = .compose
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accentText)
            .padding(10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Error

    private func errorScreen(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text("△ \(message)")
                .font(.system(size: 12))
                .foregroundStyle(warn)
                .multilineTextAlignment(.center)
            Text("Your draft is kept. Add a provider, then refine again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to draft") { model.screen = .compose }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
                .padding(10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    // MARK: - Result

    private var result: some View {
        VStack(alignment: .leading, spacing: 0) {
            backBar(title: model.proposal?.provider ?? "") { model.screen = .compose }

            ScrollView {
                Text(shownText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.peeking ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
            .padding(.horizontal, 14).padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                peekButton
                deltaStrip
                rationale
                chips
            }
            .padding(.horizontal, 14).padding(.top, 8)

            Rectangle().fill(hair).frame(height: 1).padding(.top, 8)
            footer.padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private var shownText: String {
        model.peeking ? model.draft : (model.proposal?.proposed ?? "")
    }

    private var peekButton: some View {
        Text(model.peeking ? "your original draft" : "hold to compare")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(model.peeking ? Color.primary : accentText)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.peeking = true }
                    .onEnded { _ in model.peeking = false }
            )
            .help("Press and hold to see your original draft in the same spot")
    }

    private var deltaStrip: some View {
        let before = PromptRefinerService.metrics(model.draft)
        let after = PromptRefinerService.metrics(model.proposal?.proposed ?? "")
        return HStack {
            delta("LN", before.lines, after.lines)
            Spacer()
            delta("B", before.bytes, after.bytes)
            Spacer()
            delta("TOK", before.approxTokens, after.approxTokens)
        }
    }

    private func delta(_ label: String, _ before: Int, _ after: Int) -> some View {
        let d = after - before
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(d >= 0 ? "+\(d)" : "\(d)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("\(label): \(before) before, \(after) after")
    }

    @ViewBuilder
    private var rationale: some View {
        let why = model.proposal?.why ?? []
        if !why.isEmpty {
            let setting = RefinerSettings.rationale
            let shown = setting.isVisible(for: model.mode) || whyExpanded
            VStack(alignment: .leading, spacing: 5) {
                if !setting.isVisible(for: model.mode) && setting.isExpandable {
                    Button {
                        whyExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text(whyExpanded ? "▾" : "▸").font(.system(size: 9)).foregroundStyle(.tertiary)
                            dl("WHY IT'S BETTER")
                            Spacer()
                            Text("\(why.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if shown {
                    ForEach(why, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 7) {
                            Text("·").foregroundStyle(accentText)
                            Text(bullet).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(RefinerNudge.allCases) { nudge in
                Button { startRefine(nudge: nudge) } label: {
                    Text(nudge.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(accentText)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(hair) }
                }
                .buttonStyle(.plain)
                .help(nudge.instruction)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.screen == .applied {
            HStack {
                HStack(spacing: 4) {
                    Text("✓").foregroundStyle(accentText)
                    Text(appliedLabel).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                Spacer()
                Button("Done") { model.screen = .home }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(accentText)
                    .padding(.vertical, 12)
            }
            .frame(minHeight: 44)
        } else {
            applyRow
        }
    }

    private var appliedLabel: String {
        if model.mode == .mission { return "Saved as the next mission objective." }
        switch RefinerSettings.output {
        case .insert: return "In the terminal — you press ⏎."
        case .copy:   return "Copied to the clipboard."
        case .send:   return "Sent."
        }
    }

    private var applyRow: some View {
        HStack(spacing: 8) {
            Button { apply() } label: {
                Text(applyLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(accentFill, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(applyHelp)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.proposal?.proposed ?? "", forType: .string)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copied ? accentText : .secondary)
                    .frame(width: 72, height: 44)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(hair) }
            }
            .buttonStyle(.plain)
            .help("Copy the proposal")
        }
    }

    private var applyLabel: String {
        if model.mode == .mission { return "Set as mission objective" }
        switch RefinerSettings.output {
        case .insert: return "Insert — you fire"
        case .copy: return "Copy"
        case .send: return "Send now"
        }
    }

    private var applyHelp: String {
        if model.mode == .mission {
            return "Fills the objective of the next mission handoff. Nothing is launched."
        }
        switch RefinerSettings.output {
        case .insert: return "Pastes into the terminal input. Never presses Enter."
        case .copy:   return "Puts the proposal on the clipboard."
        case .send:   return "Sends immediately — the only mode that spends without a second look."
        }
    }

    // MARK: - Actions

    private func apply() {
        guard let text = model.proposal?.proposed else { return }
        if model.mode == .mission {
            model.pendingMissionObjective = text
            model.screen = .applied
            return
        }
        switch RefinerSettings.output {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .insert, .send:
            let inserted = cockpit.insertDraft(text)
            guard inserted else {
                model.fail("Nothing was inserted — the proposal was empty or contained a control sequence.")
                return
            }
            if RefinerSettings.output == .send,
               let term = cockpit.active?.terminal as? DroppableTerminalView {
                term.sendProgrammatic(txt: "\r")
            }
        }
        model.screen = .applied
    }

    private func startRefine(nudge: RefinerNudge?) {
        guard let tab = cockpit.active else {
            model.fail("No active session.")
            return
        }
        let source = nudge == nil ? model.draft : (model.proposal?.proposed ?? model.draft)
        startedAt = Date()
        model.screen = .loading
        task?.cancel()
        task = Task {
            do {
                let refinement = try await PromptRefinerService.refine(
                    draft: source, mode: model.mode, runtime: tab.runtime, nudge: nudge,
                    projectName: tab.projectName, projectPath: tab.cwd)
                guard !Task.isCancelled else { return }
                model.accept(refinement)
            } catch {
                guard !Task.isCancelled else { return }
                model.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Chrome

    private func backBar(title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("‹ Back", action: action)
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accentText)
            dl(title)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(hair).frame(height: 1) }
    }

    private func dl(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func metricsLabel(_ text: String) -> String {
        let m = PromptRefinerService.metrics(text)
        return "\(m.lines) ln · \(m.bytes) B · ≈\(m.approxTokens) tok"
    }
}
