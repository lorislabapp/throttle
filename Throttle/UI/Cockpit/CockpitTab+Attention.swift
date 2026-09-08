import AppKit
import SwiftTerm
import SwiftUI

extension CockpitTab {

    /// A detected question settled on the PTY. Flag attention + log it (deduped
    /// against the latest), then let the model decide whether to notify.
    func handlePrompt(_ question: String) {
        if questions.last?.text == question { return }
        questions.append(Question(text: question))
        if questions.count > 8 { questions.removeFirst(questions.count - 8) }

        // PTY text is only an attention signal. It cannot grant permission,
        // even when an earlier release saved an auto-approval preference.
        needsInput = true
        onQuestion?(self, question)
    }
    func handleRateLimit(_ reset: Date?) {
        let until = reset ?? Date().addingTimeInterval(3600)
        // Only escalate on a fresh hit (not every repaint of the same banner).
        let wasLimited = isRateLimited
        rateLimitedUntil = until
        if !wasLimited { onRateLimited?(self) }
    }

    /// User is now looking at this session → clear the attention flag.
    func clearAttention() { needsInput = false }
}
