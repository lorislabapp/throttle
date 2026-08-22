import Foundation
import ThrottleShared
import os

/// Runs, on this Mac, the things a session offloaded to the box cannot do itself.
///
/// A session moved to the edge box gets CPU and memory back but loses the whole
/// Apple toolchain: no Xcode, no simulators, no signing identity, no macOS. Until
/// now that meant the work simply stopped when it reached a build. This service
/// lets the remote session ask for a **named capability** — `build`, `test`,
/// `lint` — and answers with the result.
///
/// ## Why a name and not a command
///
/// The obvious design is to let the box send a command string for the Mac to run.
/// That is a shell on the laptop, offered to a machine that is by definition less
/// trusted than the laptop — and reachable by anything that compromises the box.
/// So the request carries a capability *name* and a bounded map of scalar
/// arguments; this file, on the Mac, owns the mapping from name to command. A
/// fully compromised box gets a build. It does not get `rm`.
///
/// Two more limits follow from the same reasoning:
///   • the working directory is derived from the mirror name and must resolve
///     inside `~/GitHub` — the box cannot point the Mac at an arbitrary path,
///   • output is capped, because the session's context is not free and a failing
///     build emits megabytes.
///
/// Polling, not pushing: the Mac reaches out to the box. Nothing on the box can
/// open a connection to the laptop, which keeps the direction of trust intact.
@MainActor
final class CapabilityHostService: ObservableObject {

    /// What the Mac is willing to do on request. Adding a case here is a
    /// deliberate act of trust — it is the entire attack surface.
    enum Capability: String, CaseIterable, Sendable {
        case build, test, lint

        /// The command this capability maps to. Arguments coming from the box are
        /// interpolated only where a value is expected, never as a command.
        func command(cwd: String, args: [String: String]) -> (launch: String, argv: [String])? {
            let scheme = Self.safe(args["scheme"])
            let configuration = Self.safe(args["configuration"]) ?? "Debug"
            switch self {
            case .build, .test:
                guard let scheme else { return nil }
                let action = self == .build ? "build" : "test"
                return ("/usr/bin/xcodebuild", [
                    "-scheme", scheme, "-configuration", configuration,
                    "-destination", "platform=macOS",
                    "-skipPackagePluginValidation", "-skipMacroValidation", action,
                ])
            case .lint:
                return ("/usr/bin/env", ["swiftlint", "lint", "--quiet", cwd])
            }
        }

        /// Arguments are values, so they may only look like values. Anything with
        /// a shell metacharacter, a newline, or a path separator is dropped rather
        /// than escaped — escaping invites a bypass, refusing does not.
        private static func safe(_ v: String?) -> String? {
            guard let v, !v.isEmpty, v.count <= 128,
                  v.allSatisfy({ $0.isLetter || $0.isNumber || "._- ".contains($0) })
            else { return nil }
            return v
        }
    }

    static let shared = CapabilityHostService()

    @Published private(set) var lastRun: String?
    @Published private(set) var running = false
    /// Off unless the user turns it on, and off again on a fresh install.
    /// Executing anything on behalf of another machine is a decision, not a
    /// default.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    private static let enabledKey = "capabilityHostEnabled"

    private static let log = Logger(subsystem: "com.lorislab.throttle", category: "capability-host")
    nonisolated static let outputCap = 64_000
    nonisolated static let timeout: TimeInterval = 15 * 60

    private var pollTask: Task<Void, Never>?

    /// Where the box lives. Owned by `RemoteSessionsService` — one place holds the
    /// host and the bearer token, and it is not this file.
    private var remote: (String, String) {
        let svc = RemoteSessionsService.shared
        return (svc.baseURL, svc.token)
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Called once at launch. A no-op unless the user previously turned it on.
    func restoreIfEnabled() { if enabled { start() } }

    /// A `Task` loop rather than a `Timer`.
    ///
    /// The first version used `Timer.scheduledTimer`, and it never fired once in
    /// production: the request sat pending on the box for 35 minutes with the
    /// feature enabled, the route reachable and the code present in the shipped
    /// binary. `RemoteSessionsService` polls the same agent with a task loop and
    /// has always worked, so this now does what is known to work in this app
    /// instead of what should work in principle.
    func start(poll every: TimeInterval = 20) {
        stop()
        guard enabled else { return }
        Self.log.info("capability host started, polling every \(Int(every))s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// One pass: ask the box what it needs, serve at most one request. One at a
    /// time on purpose — a build already saturates this machine, and the reason
    /// the session moved to the box was that the Mac had nothing left to give.
    func pollOnce() async {
        guard enabled, !running else { return }
        guard let pending = await fetchPending() else {
            // Silence here is what made the first version undiagnosable from the
            // outside: enabled, reachable, shipped — and no way to tell it never
            // asked.
            Self.log.debug("capability poll: the box did not answer")
            return
        }
        guard let req = pending.first else { return }
        Self.log.info("capability poll: \(pending.count, privacy: .public) request(s) waiting")
        guard let capability = Capability(rawValue: req.capability) else {
            await report(req.id, exitCode: nil, output: "", error: "capability '\(req.capability)' is not offered by this Mac")
            return
        }
        guard let cwd = resolveRepo(req.repo) else {
            await report(req.id, exitCode: nil, output: "", error: "no repo named '\(req.repo)' under ~/GitHub on this Mac")
            return
        }
        guard let cmd = capability.command(cwd: cwd, args: req.args ?? [:]) else {
            await report(req.id, exitCode: nil, output: "", error: "\(req.capability) needs a valid 'scheme' argument")
            return
        }

        running = true
        lastRun = "\(req.capability) · \(req.repo)"
        defer { running = false }
        Self.log.info("serving capability \(req.capability, privacy: .public) for \(req.repo, privacy: .public)")

        let result = await run(cmd.launch, cmd.argv, cwd: cwd)
        await report(req.id, exitCode: result.code, output: result.output, error: nil)
    }

    /// A mirror name maps to exactly one directory, and only inside `~/GitHub`.
    /// The name is matched against directory names on disk rather than joined
    /// into a path, so no amount of `..` in the request escapes the tree.
    private func resolveRepo(_ name: String) -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("GitHub", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        // Compare on a folded form: the box speaks ASCII mirror names while the
        // directory may be "Éclair". Same trap as the sync script.
        let wanted = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard let hit = entries.first(where: {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) == wanted
        }) else { return nil }
        let dir = root.appendingPathComponent(hit, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return dir.path
    }

    private func run(_ launch: String, _ argv: [String], cwd: String) async -> (code: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launch)
                p.arguments = argv
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                guard (try? p.run()) != nil else {
                    cont.resume(returning: (-1, "could not launch \(launch)")); return
                }
                // A build that never ends must not pin this machine forever; the
                // session gets a timeout it can act on instead of silence.
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                // Keep the tail: the error and the summary live at the end of a
                // build log, the preamble is boilerplate.
                let text = String(data: data, encoding: .utf8) ?? ""
                let trimmed = text.count > Self.outputCap ? String(text.suffix(Self.outputCap)) : text
                cont.resume(returning: (p.terminationStatus, trimmed))
            }
        }
    }

    // MARK: - Talking to the box

    private func fetchPending() async -> [EdgeAgentService.CapabilityRequest]? {
        let (base, token) = remote
        guard !base.isEmpty, !token.isEmpty else { return nil }
        return try? await EdgeAgentService.pendingCapabilities(baseURL: base, token: token)
    }

    private func report(_ id: String, exitCode: Int32?, output: String, error: String?) async {
        let (base, token) = remote
        guard !base.isEmpty, !token.isEmpty else { return }
        try? await EdgeAgentService.completeCapability(baseURL: base, token: token, id: id,
                                                       exitCode: exitCode, output: output, error: error)
    }
}
