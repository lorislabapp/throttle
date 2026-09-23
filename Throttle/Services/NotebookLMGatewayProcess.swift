import Darwin
import Foundation

enum NotebookLMGatewayClientError: Error, Equatable {
    case unavailable
    case invalidConfiguration
    case launchFailed
    case timeout
    case terminationUnconfirmed
    case responseTooLarge
    case invalidResponse
    case gatewayRejected(String)
}

/// Bounded stdio exchange used by NotebookLMGatewayClient. Reuses the owned
/// child signal/reap authority; process groups do not prove confinement.
enum NotebookLMGatewayProcess {
    static let maximumResponseBytes = 8 * 1_024 * 1_024

    /// One owned child/group; no task-group waits on a blocking pipe read.
    static func execute(
        executable: String, arguments: [String], environment: [String: String],
        request: Data, timeout: TimeInterval
    ) async throws -> Data {
        guard timeout.isFinite, timeout > 0, request.count <= maximumResponseBytes else {
            throw NotebookLMGatewayClientError.invalidConfiguration
        }
        try Task.checkCancellation()
        let connection = try spawn(executable: executable, arguments: arguments, environment: environment)
        var inputOpen = true
        defer {
            if inputOpen { close(connection.input) }
            close(connection.child.readFD)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result: Result<Data, Error>
        do {
            try await writeRequest(request, descriptor: connection.input, deadline: deadline)
            close(connection.input)
            inputOpen = false
            result = .success(try await readResponse(descriptor: connection.child.readFD, deadline: deadline))
        } catch { result = .failure(error) }
        // Cleanup must outlive caller cancellation, but remains time-bounded.
        let stopped = await Task.detached { await stop(connection.child) }.value
        guard stopped else { throw NotebookLMGatewayClientError.terminationUnconfirmed }
        try Task.checkCancellation()
        return try result.get()
    }

    private static func writeRequest(_ data: Data, descriptor: Int32, deadline: TimeInterval) async throws {
        var offset = 0
        while offset < data.count {
            try checkDeadline(deadline)
            let count = data.withUnsafeBytes {
                write(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count; continue }
            guard count < 0, errno == EAGAIN || errno == EINTR else {
                throw NotebookLMGatewayClientError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func readResponse(descriptor: Int32, deadline: TimeInterval) async throws -> Data {
        var buffer = [UInt8](), total = 0
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkDeadline(deadline)
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN || errno == EINTR {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            guard count > 0 else { throw NotebookLMGatewayClientError.invalidResponse }
            total += count
            guard total <= maximumResponseBytes else { throw NotebookLMGatewayClientError.responseTooLarge }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if responseIdentifier(line) == 2 { return line }
            }
        }
    }

    private static func checkDeadline(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw NotebookLMGatewayClientError.timeout }
    }

    private static func stop(_ child: TaskIntegrationService.ChildControl) async -> Bool {
        child.signal(SIGTERM)
        if !(await groupStopped(child, within: 0.15)) {
            child.signal(SIGKILL)
            _ = await groupStopped(child, within: 1)
        }
        var info = siginfo_t()
        let observed = waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0
            && info.si_pid == child.pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code)
        guard observed else { return false }
        let groupEmpty = child.groupIsEmpty
        _ = child.waitUntilExit()
        return child.reap() && groupEmpty
    }

    private static func groupStopped(
        _ child: TaskIntegrationService.ChildControl, within timeout: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !child.groupIsEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func responseIdentifier(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

}

extension NotebookLMGatewayProcess {
    private struct Connection: Sendable {
        let child: TaskIntegrationService.ChildControl
        let input: Int32
    }

    private static func spawn(
        executable: String, arguments: [String], environment: [String: String]
    ) throws -> Connection {
        let input = try pipePair()
        let output: [Int32]
        do { output = try pipePair() } catch {
            input.forEach { close($0) }
            throw error
        }
        var transferred = false
        defer {
            close(input[0]); close(output[1])
            if !transferred { close(input[1]); close(output[0]) }
        }
        try checked(fcntl(input[1], F_SETNOSIGPIPE, 1))
        for descriptor in [input[1], output[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0 else { throw NotebookLMGatewayClientError.launchFailed }
            try checked(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK))
        }
        let pid = try launch(executable: executable, arguments: arguments, environment: environment,
                             input: input[0], output: output[1])
        transferred = true
        return Connection(child: TaskIntegrationService.ChildControl(pid: pid, readFD: output[0]), input: input[1])
    }

    /// GUI hosts may have closed 0/1/2. Match the verification gate's pattern:
    /// own descriptors >= 10 before any child dup2/addopen can overwrite them.
    private static func pipePair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw NotebookLMGatewayClientError.launchFailed }
        defer { descriptors.forEach { close($0) } }
        let input = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 10)
        guard input >= 0 else { throw NotebookLMGatewayClientError.launchFailed }
        let output = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 10)
        guard output >= 0 else {
            close(input)
            throw NotebookLMGatewayClientError.launchFailed
        }
        return [input, output]
    }

    private static func launch(
        executable: String, arguments: [String], environment: [String: String], input: Int32, output: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = -1
        try checked(posix_spawn(&pid, executable, &actions, &attributes, &argv, &env))
        return pid
    }

    private static func checked(_ result: Int32) throws {
        guard result == 0 else {
            throw NotebookLMGatewayClientError.launchFailed
        }
    }
}
