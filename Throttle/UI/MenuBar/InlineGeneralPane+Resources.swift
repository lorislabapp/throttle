import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineGeneralPane {
    @ViewBuilder
    var resourceSettings: some View {
        SettingsHair()
        SettingsRow(title: "Low-memory mode",
                    sub: "Off by default. One switch for a RAM-constrained Mac (16 GB) — tightens every reclaim lever at once so you don't tune four settings: forces auto-hibernate on, reclaims idle sessions after 5 min (not 15), caps concurrent live sessions at 3, defaults the Node heap to 3072 MB when unset, and trims the terminal scrollback to 150 rows to cut per-scroll redraw. Reversible; never overwrites your individual settings, just shadows them while on.") {
            Toggle("", isOn: $lowMemoryMode).labelsHidden().toggleStyle(.switch).tint(.orange)
        }
        SettingsHair()
        SettingsRow(title: "Auto-pause near the cap",
                    sub: "Off by default. At 95% with the wall under 5 min away, Throttle shows a 10-second cancelable countdown, then waits for a quiet moment in the transcript (no stream/write in flight) before freezing (SIGSTOP) the runaway session — or all live ones if none is looping. Reversible: resume anytime, nothing lost.") {
            Toggle("", isOn: $autoPauseEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
        SettingsHair()
        SettingsRow(title: "Pause Opus/Fable sessions past a token cap",
                    sub: "Off by default. A per-session rule: when a premium-model session (Opus, Fable) crosses the cap below, Throttle freezes it (SIGSTOP) and notifies you — big-model sessions that balloon are the #1 silent spend. Resume anytime from the rail; it won't re-pause until the session drops back under the cap.") {
            HStack(spacing: 8) {
                if opusCapEnabled {
                    Stepper(value: $opusCapK, in: 50...1000, step: 50) {
                        Text("\(opusCapK)k").font(.system(size: 11, design: .monospaced))
                    }.controlSize(.small)
                }
                Toggle("", isOn: $opusCapEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
        }
        SettingsHair()
        SettingsRow(title: "Auto-hibernate idle sessions under memory pressure",
                    sub: "On by default. When the Mac hits critical memory pressure, Throttle hibernates cockpit sessions idle 15+ min — kills the ~300 MB–1 GB subtree, keeps the resume-id — to free real RAM (SIGSTOP pause only freezes tokens, not memory). Never the active/working/waiting session. Reversible: reopen the tab to resume with full context via --resume.") {
            Toggle("", isOn: $autoHibernateEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
        SettingsHair()
        SettingsRow(title: "Auto-trim idle transcripts",
                    sub: "Off by default. On launch, Throttle shrinks the heaviest idle past-session .jsonl files — replaces already-seen base64 images with a rehydratable pointer so `claude --resume` reloads a lighter file and re-charges fewer tokens. Lossless + reversible: whole-file backups in ~/.claude/throttle-backups, and the model can pull any image back via throttle_expand_pointer. Never touches a session idle < 10 min.") {
            Toggle("", isOn: $autoTrimEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
        }
        SettingsHair()
        SettingsRow(title: "Cap Node heap per session",
                    sub: "Off by default. Sets NODE_OPTIONS=--max-old-space-size for each Cockpit session before launching claude — bounds the V8 heap so many concurrent sessions swap less. 0 = off. ⚠️ Too low crashes claude on a big context (\"JS heap out of memory\"); 4096+ is safe for most, drop toward 1536 only if you run many light sessions.") {
            TextField("0", value: $nodeHeapCapMB, format: .number)
                .frame(width: 64).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
        SettingsHair()
        SettingsRow(title: "Limit sub-agents per session",
                    sub: "Off by default. Appends --max-agents to the claude launch to cap parallel sub-agents (each is another process). 0 = off. Verify your Claude Code version supports the flag before enabling.") {
            TextField("0", value: $maxAgents, format: .number)
                .frame(width: 64).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }
}
