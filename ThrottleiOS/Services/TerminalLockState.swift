import Foundation
import LocalAuthentication

/// The non-negotiable write-unlock gate for edge-agent terminals (Kevin's
/// architecture verdict, 2026-07-11): the terminal is read-only until a local
/// Face ID/Touch ID unlock, and auto re-locks after 5 min of no keystrokes. This is
/// a UX safety net enforced client-side, not a hard security boundary — ttyd itself
/// accepts input the moment a socket is attached; a compromised/jailbroken device
/// could bypass this the same way it could exfiltrate the token already sitting in
/// UserDefaults. One `TerminalLockState` per attached terminal (not shared/global).
@MainActor
@Observable
final class TerminalLockState {
    private(set) var unlocked = false
    private var idleTask: Task<Void, Never>?
    private let idleInterval: UInt64 = 300 * 1_000_000_000 // 5 min, in nanoseconds

    /// Prompt for biometrics; on success, unlock and start the idle countdown.
    @discardableResult
    func unlock() async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return false }
        guard let ok = try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                     localizedReason: "Unlock to type into this remote session"),
              ok else { return false }
        unlocked = true
        scheduleRelock()
        return true
    }

    /// Call on every keystroke sent — resets the idle countdown. No-op while locked.
    func noteActivity() {
        guard unlocked else { return }
        scheduleRelock()
    }

    func lock() { idleTask?.cancel(); idleTask = nil; unlocked = false }

    private func scheduleRelock() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.idleInterval ?? 0)
            guard let self, !Task.isCancelled else { return }
            self.unlocked = false
        }
    }
}
