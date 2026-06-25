import Foundation

/// `Throttle --mcp-wrap <command> [args…]` — a transparent stdio supervisor for a
/// single MCP server (v3.0 Pillar 2, proxy Pattern-B, opt-in). The user wraps ONE
/// server's command by hand (Throttle never rewrites config); this process then:
///   • passes the client's stdin straight to the child, child stdout straight back
///     (raw byte passthrough — the client can't tell Throttle is in the middle);
///   • DRAINS the child's stderr so a full stderr buffer can't hang it (#1935 class);
///   • RESPAWNS the child if it dies and replays the captured initialize handshake,
///     so a server crash self-heals instead of silently dying (#45146 class);
///   • backs off + circuit-breaks so a crash-looping server doesn't thrash.
///
/// Safety: pure passthrough, never mutates the JSON-RPC payloads. On its own
/// failure it exits, which degrades to today's behavior (client sees a disconnect).
enum MCPWrapper {

    static func run(_ wrapped: [String]) -> Never {
        guard let cmd = wrapped.first else { FileHandle.standardError.write(Data("throttle --mcp-wrap: no command\n".utf8)); exit(2) }
        let args = Array(wrapped.dropFirst())
        let sup = Supervisor(command: cmd, args: args)
        sup.start()
        // Pump our stdin → current child (persists across respawns); capture the
        // initialize + initialized handshake to replay after a respawn.
        let stdin = FileHandle.standardInput
        stdin.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { exit(0) }            // client closed the pipe → we're done
            sup.captureHandshake(d)
            sup.sendToChild(d)
        }
        dispatchMain()
    }

    /// Owns the child lifecycle on a serial queue (no races between pump + respawn).
    private final class Supervisor: @unchecked Sendable {
        private let command: String
        private let args: [String]
        private let q = DispatchQueue(label: "throttle.mcpwrap")
        private var child: Process?
        private var childIn: FileHandle?
        // Retain the pipes for the child's lifetime — if they deallocate, their FDs
        // close and the child gets stdin EOF and exits (that was the crash-loop).
        private var inPipe: Pipe?
        private var outPipe: Pipe?
        private var errPipe: Pipe?
        private var handshake = Data()          // bytes up to & including notifications/initialized
        private var handshakeDone = false
        private var restarts: [Date] = []       // for the circuit breaker
        private let out = FileHandle.standardOutput

        init(command: String, args: [String]) { self.command = command; self.args = args }

        func start() { q.async { self.spawn() } }

        func sendToChild(_ d: Data) { q.async { try? self.childIn?.write(contentsOf: d) } }

        /// Capture the initialize request + the initialized notification so a respawn
        /// can replay them and the client never has to re-handshake.
        func captureHandshake(_ d: Data) {
            q.async {
                guard !self.handshakeDone else { return }
                self.handshake.append(d)
                if let s = String(data: self.handshake, encoding: .utf8),
                   s.contains("notifications/initialized") { self.handshakeDone = true }
            }
        }

        private func spawn() {
            // Circuit breaker: >5 restarts in 60s → stop thrashing, let it die.
            let now = Date()
            restarts = restarts.filter { now.timeIntervalSince($0) < 60 }
            if restarts.count >= 5 {
                FileHandle.standardError.write(Data("throttle --mcp-wrap: \(command) crash-looping, giving up\n".utf8))
                exit(1)
            }

            let p = Process()
            // Exec the wrapped command DIRECTLY — the wrapper already inherits the
            // exact environment Claude Code set for this server, so no login shell
            // (and no shell-quoting) is needed. Resolve a bare name via PATH.
            p.executableURL = command.contains("/")
                ? URL(fileURLWithPath: command)
                : URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = command.contains("/") ? args : ([command] + args)

            let inP = Pipe(), outP = Pipe(), errP = Pipe()
            inPipe = inP; outPipe = outP; errPipe = errP   // retain for the child's life
            p.standardInput = inP; p.standardOutput = outP; p.standardError = errP
            // Drain stderr to nowhere so the child can't block on a full buffer.
            errP.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
            // Child stdout → our stdout, byte-for-byte.
            outP.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if !d.isEmpty { self?.out.write(d) }
            }
            p.terminationHandler = { [weak self] _ in
                guard let self else { return }
                // Stop the dead pipes' handlers so they don't spin on closed FDs.
                outP.fileHandleForReading.readabilityHandler = nil
                errP.fileHandleForReading.readabilityHandler = nil
                self.q.asyncAfter(deadline: .now() + 0.4) { self.spawn() }   // small backoff
            }
            do { try p.run() } catch {
                FileHandle.standardError.write(Data("throttle --mcp-wrap: spawn failed: \(error)\n".utf8))
                exit(1)
            }
            child = p
            childIn = inP.fileHandleForWriting
            if !restarts.isEmpty || handshakeDone {   // a respawn → replay the handshake
                if !handshake.isEmpty { try? childIn?.write(contentsOf: handshake) }
            }
            restarts.append(now)
        }
    }
}
