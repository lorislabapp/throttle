import Foundation

/// The three small machines `TaskIntegrationServiceVerify.swift` runs a project's
/// command on: the child process and its group, the pipe it writes to, and the
/// buffer that pipe fills. Split out of that file to stay under SwiftLint's
/// `file_length`; they belong to `shell()` and to nothing else.
///
/// They are nested rather than top-level so the namespace still says who owns them,
/// and internal rather than `private` only because Swift's `private` does not cross
/// files.
extension TaskIntegrationService {

    /// Drains the read end of the pipe on its own queue until EOF, and owns that
    /// descriptor's lifetime.
    ///
    /// A `DispatchSource` rather than `FileHandle.readabilityHandler`: the handler can
    /// fire once more after being cleared, and `availableData` on a descriptor that
    /// has since been closed raises `NSFileHandleOperationException` — an uncatchable
    /// Objective-C exception in the middle of a verification.
    final class PipeReader {
        private let descriptor: Int32
        private let source: DispatchSourceRead
        private let stopped: DispatchSemaphore

        init(descriptor: Int32, into collector: OutputCollector, drained: DispatchGroup) {
            self.descriptor = descriptor
            let stopped = DispatchSemaphore(value: 0)
            self.stopped = stopped
            // `shell` is an explicit user action and waits, bounded, for this reader
            // to signal EOF/cancellation. Keep the signaling side at least as urgent
            // as its possible UI waiter so the wait cannot invert queue priorities.
            // The queue does no command work: it only drains already-available bytes.
            let queue = DispatchQueue(
                label: "com.lorislab.throttle.verify-output",
                qos: .userInteractive
            )
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            self.source = source
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    collector.append(Data(buffer[0..<count]))
                    return
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
                if collector.consumeEOF() { drained.leave() }
                source.cancel()
            }
            source.setCancelHandler { stopped.signal() }
            source.resume()
        }

        /// Stops reading and closes the descriptor — on the caller's thread, and only
        /// once libdispatch has confirmed through the cancel handler that the event
        /// handler will not run again.
        ///
        /// The confirmation is the whole point. Closing *from* the cancel handler let
        /// the close land after `shell` had already returned, by which time the process
        /// had handed that descriptor number to the next `Pipe` git was reading — and
        /// a `read` blocked on a descriptor closed under it never returns on Darwin.
        /// The symptom was a later, unrelated git call hanging for ever, with nothing
        /// in its own stack to explain why.
        ///
        /// On the timeout the descriptor is leaked rather than closed: one leaked
        /// descriptor is cheaper than closing somebody else's.
        func finish(within grace: TimeInterval) {
            source.cancel()
            guard stopped.wait(timeout: .now() + grace) == .success else { return }
            close(descriptor)
        }
    }

    /// What one signal from `ChildControl` did: whether anything received it, and
    /// whether the child itself was still running when it went out.
    ///
    /// A sibling of `ChildControl` rather than a member of it, only because
    /// SwiftLint's `nesting` allows one level and this file is already one deep.
    struct SignalOutcome {
        let sent: Bool
        /// The child had not been reaped, so this interrupted a run in progress rather
        /// than chasing what that run left behind. Only this may be read as a timeout:
        /// a timeout is a statement about the run, and a run that had already finished
        /// did not time out however many stragglers it left.
        let interruptedTheRun: Bool

        static let nothing = SignalOutcome(sent: false, interruptedTheRun: false)
    }

    /// Buffers a subprocess's output as the read source delivers it — on its own
    /// queue, distinct from the queue the timeout escalation runs on — so both sides
    /// go through a lock rather than a plain var.
    final class OutputCollector: @unchecked Sendable {
        static let byteLimit = 64 * 1024
        private let lock = NSLock()
        private var buffer = Data()
        private var receivedBytes = 0
        private var hasTimedOut = false
        private var eofSeen = false

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            let (total, overflow) = receivedBytes.addingReportingOverflow(chunk.count)
            receivedBytes = overflow ? Int.max : total
            if chunk.count >= Self.byteLimit {
                buffer = Data(chunk.suffix(Self.byteLimit))
                return
            }
            let retainedCount = Self.byteLimit - chunk.count
            if buffer.count > retainedCount {
                // Copy so a slice cannot retain an old allocation. Keep draining
                // the pipe after reaching the cap instead of blocking the child.
                buffer = Data(buffer.suffix(retainedCount))
            }
            buffer.append(chunk)
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            hasTimedOut = true
        }

        /// True only the first call. Both the read source and `shell`'s own tail
        /// reach for it, and the drain group must be left exactly once.
        func consumeEOF() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if eofSeen { return false }
            eofSeen = true
            return true
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return hasTimedOut
        }

        var output: String {
            lock.lock(); defer { lock.unlock() }
            // A byte boundary can split a UTF-8 scalar. Repair it rather than
            // discarding the whole diagnostic when decoding fails.
            // Lossy UTF-8 is deliberate for a subprocess byte stream; a failable
            // conversion would erase all diagnostics for one partial scalar.
            // swiftlint:disable:next optional_data_string_conversion
            var text = String(decoding: buffer, as: UTF8.self)
            if receivedBytes > buffer.count {
                text += TaskIntegrationService.outputTruncationNotice
            }
            return text
        }

        var retainedByteCount: Int {
            lock.lock(); defer { lock.unlock() }
            return buffer.count
        }
    }
}
