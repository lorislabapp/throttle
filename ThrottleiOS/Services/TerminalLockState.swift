import Foundation
import LocalAuthentication

/// Opt-in write lock for remote terminals. **Unlocked by default** (2026-07-17):
/// the original read-only-until-Face-ID default (verdict of 2026-07-11) made the
/// terminal look broken — the keyboard never took focus and keystrokes were dropped
/// without a word, so "I can't type on iOS" was the whole experience.
///
/// It was never a security boundary anyway: ttyd accepts input the moment a socket
/// attaches, and the token already sits in UserDefaults, so a compromised device
/// bypasses this trivially. It only ever bought protection against *your own* stray
/// taps — which is worth a button, not a wall.
///
/// Now: type immediately; tap the lock to make a session read-only on purpose;
/// typing into a locked session prompts to unlock instead of silently swallowing it.
/// No idle auto-relock — that would silently re-arm the same trap mid-session.
/// One `TerminalLockState` per attached terminal (not shared/global).
@MainActor
@Observable
final class TerminalLockState {
    private(set) var unlocked = true

    /// Why the last unlock attempt failed, for the UI to surface a recovery hint.
    private(set) var lastError: String?

    /// Prompt for biometrics **with device-passcode fallback**, so a user with no
    /// enrolled Face ID / Touch ID (or one that's hit biometry lockout) can still
    /// unlock — `.deviceOwnerAuthentication` falls back to the passcode automatically.
    /// On success, unlock and start the idle countdown.
    @discardableResult
    func unlock() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lastError = "This device has no passcode or biometrics set up."
            return false
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Unlock to type into this remote session")
            guard ok else { lastError = "Authentication was not confirmed."; return false }
        } catch {
            // User cancel / system cancel are not errors worth shouting about.
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
            return false
        }
        lastError = nil
        unlocked = true
        return true
    }

    func lock() { unlocked = false }

    /// A keystroke arrived while locked. Raise the unlock prompt once rather than
    /// dropping the key in silence — a terminal that ignores your typing with no
    /// explanation is the bug we're fixing, not a safety feature.
    private var prompting = false
    func requestUnlockForTyping() {
        guard !unlocked, !prompting else { return }
        prompting = true
        Task { [weak self] in
            await self?.unlock()
            self?.prompting = false
        }
    }
}
