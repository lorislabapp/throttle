import Foundation
import LocalAuthentication

/// Local write gate for remote terminals. Every terminal starts read-only, asks for
/// device-owner authentication on the first attempted write, and relocks after five
/// minutes without outgoing input or whenever the app leaves the foreground.
///
/// This protects against accidental/unauthorized writes on an unlocked phone; it is
/// deliberately not described as end-to-end authorization for the remote agent.
/// One `TerminalLockState` is owned by each attached terminal.
@MainActor
@Observable
final class TerminalLockState {
    private(set) var unlocked = false

    /// Why the last unlock attempt failed, for the UI to surface a recovery hint.
    private(set) var lastError: String?

    private let relockAfterNanoseconds: UInt64
    private let authenticationOverride: (@MainActor () async -> Bool)?
    private var relockTask: Task<Void, Never>?

    init(
        relockAfterNanoseconds: UInt64 = 5 * 60 * 1_000_000_000,
        authenticationOverride: (@MainActor () async -> Bool)? = nil
    ) {
        self.relockAfterNanoseconds = relockAfterNanoseconds
        self.authenticationOverride = authenticationOverride
    }

    /// Prompt for biometrics **with device-passcode fallback**, so a user with no
    /// enrolled Face ID / Touch ID (or one that's hit biometry lockout) can still
    /// unlock — `.deviceOwnerAuthentication` falls back to the passcode automatically.
    /// On success, unlock and start the idle countdown.
    @discardableResult
    func unlock() async -> Bool {
        if let authenticationOverride {
            guard await authenticationOverride() else {
                lastError = "Authentication was not confirmed."
                return false
            }
            completeUnlock()
            return true
        }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lastError = "This device has no passcode or biometrics set up."
            return false
        }
        do {
            let authenticated = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock to type into this remote session"
            )
            guard authenticated else { lastError = "Authentication was not confirmed."; return false }
        } catch {
            // User cancel / system cancel are not errors worth shouting about.
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
            return false
        }
        completeUnlock()
        return true
    }

    func lock() {
        relockTask?.cancel()
        relockTask = nil
        unlocked = false
    }

    /// Call immediately before every outgoing terminal write. A write is the only
    /// activity that extends the unlock window; passive output never does.
    func registerWriteActivity() {
        guard unlocked else { return }
        scheduleRelock()
    }

    private func completeUnlock() {
        lastError = nil
        unlocked = true
        scheduleRelock()
    }

    private func scheduleRelock() {
        relockTask?.cancel()
        let delay = relockAfterNanoseconds
        relockTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

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
