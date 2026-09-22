import Foundation

/// Authentication permits the mirror, not terminal control. Capture admission
/// on the network queue and recheck on MainActor, across consent revocation.
/// All mutable state is protected by lock; tickets never grant execution alone.
final class PeerControlAdmission: @unchecked Sendable {
    struct Ticket: Sendable {
        fileprivate let listener: UUID
        fileprivate let consent: UUID
    }

    private let lock = NSLock()
    private var listener: UUID?
    private var consent = UUID()
    private var controlEnabled = false

    func start(controlEnabled: Bool) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let token = UUID()
        listener = token
        consent = UUID()
        self.controlEnabled = controlEnabled
        return token
    }

    func setControlEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        consent = UUID()
        controlEnabled = enabled
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        listener = nil
        consent = UUID()
        controlEnabled = false
    }

    func ticket(for generation: UUID) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard controlEnabled, listener == generation else { return nil }
        return Ticket(listener: generation, consent: consent)
    }

    func permits(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return controlEnabled && listener == ticket.listener && consent == ticket.consent
    }

    var permitsCurrentConnection: Bool {
        lock.lock(); defer { lock.unlock() }
        return controlEnabled && listener != nil
    }
}
