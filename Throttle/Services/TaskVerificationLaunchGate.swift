import Darwin
import Foundation

/// A private admission pipe, not a persisted permission or a sandbox. The fixed
/// shell wrapper exits on EOF: a controller crash before release cannot leave
/// an indefinitely suspended, unregistered project command.
final class TaskVerificationLaunchGate {
    let readDescriptor: Int32
    private var writeDescriptor: Int32

    enum Failure: Error { case pipeCreation, descriptorSetup, admissionLost }

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.pipeCreation }
        defer { descriptors.forEach { close($0) } }
        let input = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 10)
        guard input >= 0 else { throw Failure.descriptorSetup }
        let output = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 10)
        guard output >= 0 else { close(input); throw Failure.descriptorSetup }
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else {
            close(input); close(output)
            throw Failure.descriptorSetup
        }
        readDescriptor = input
        writeDescriptor = output
    }

    deinit {
        close(readDescriptor)
        abandon()
    }

    /// One small atomic pipe write; a dead reader becomes EPIPE, never SIGPIPE
    /// delivered to Throttle. Closing without these bytes refuses admission.
    func release() throws {
        guard writeDescriptor >= 0 else { throw Failure.admissionLost }
        let bytes = Array("run\n".utf8)
        let count = bytes.withUnsafeBytes { write(writeDescriptor, $0.baseAddress, $0.count) }
        abandon()
        guard count == bytes.count else { throw Failure.admissionLost }
    }

    func abandon() {
        if writeDescriptor >= 0 { close(writeDescriptor); writeDescriptor = -1 }
    }
}
