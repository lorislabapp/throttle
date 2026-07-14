import Foundation
import ThrottleShared

/// One-click deployment of the Throttle Edge Agent: the app SSHes to the user's
/// box itself and runs each `EdgeAgentService.deploySteps` script by piping it to
/// `ssh … 'bash -s'` STDIN. This deliberately supersedes the old "the app never
/// SSHes" stance — Kevin's call (2026-07-14): "je clique offload, Throttle gère
/// tout". Piping to `bash -s` (not pasting into a shell) also kills the field
/// failure where zsh history expansion detonated on the script's `#!` line.
///
/// Everything is idempotent, so the same button is deploy AND repair. The SSH key
/// never leaves disk; BatchMode forbids password prompts (fail fast instead of
/// hanging a UI task on a TTY prompt that can never be answered).
@MainActor
@Observable
final class EdgeDeployService {
    static let shared = EdgeDeployService()
    private init() {}

    enum StepState: Equatable { case pending, running, done, failed(String) }

    struct StepStatus: Identifiable {
        let id = UUID()
        let label: String
        var state: StepState = .pending
    }

    private(set) var steps: [StepStatus] = []
    private(set) var running = false
    /// Tail of the last failure's output — shown so the user isn't debugging blind.
    private(set) var failureDetail: String?

    /// Run the full deploy. Returns true when every step succeeded.
    ///
    /// `lxcID`: when the SSH host is a Proxmox HOST fronting the agent's container
    /// (the DNAT topology — the Mac can only reach the host over Tailscale), every
    /// step is routed inside via `pct exec <id> -- bash -s`. Without it the steps
    /// would silently install the agent on the host itself — the exact trap the old
    /// copy-paste script shipped with. `pct exec` forwards stdin (verified live on
    /// PVE), so the piping model is unchanged.
    @discardableResult
    func deploy(target: EdgeAgentService.SSHTarget, token: String, httpPort: Int,
                ttydPort: Int = 8788, lxcID: String? = nil) async -> Bool {
        guard !running else { return false }
        guard let agentSource = EdgeAgentService.bundledAgentSource() else {
            steps = [StepStatus(label: "Agent source", state: .failed("throttle-agent.mjs missing from app bundle"))]
            return false
        }
        let plan = EdgeAgentService.deploySteps(token: token, httpPort: httpPort,
                                                ttydPort: ttydPort, agentSource: agentSource)
        steps = plan.map { StepStatus(label: $0.label) }
        running = true
        failureDetail = nil
        defer { running = false }

        let trimmedLxc = lxcID?.trimmingCharacters(in: .whitespaces)
        let remoteCommand: String
        if let id = trimmedLxc, !id.isEmpty {
            guard id.allSatisfy(\.isNumber) else {
                steps.insert(StepStatus(label: "LXC ID", state: .failed("container ID must be numeric")), at: 0)
                return false
            }
            remoteCommand = "pct exec \(id) -- bash -s"
        } else {
            remoteCommand = "bash -s"
        }

        for (i, step) in plan.enumerated() {
            steps[i].state = .running
            let result = await Self.runSSH(target: target, remoteScript: step.script,
                                           remoteCommand: remoteCommand)
            switch result {
            case .success:
                steps[i].state = .done
            case .failure(let message):
                steps[i].state = .failed(message)
                failureDetail = message
                return false
            }
        }
        return true
    }

    // MARK: - ssh plumbing

    private enum SSHResult { case success, failure(String) }

    /// `ssh <target> '<remoteCommand>'` with the step script on stdin. Runs
    /// off-main; 120 s guard so a dead route can't wedge the deploy forever.
    private static func runSSH(target: EdgeAgentService.SSHTarget, remoteScript: String,
                               remoteCommand: String = "bash -s",
                               timeout: TimeInterval = 120) async -> SSHResult {
        let keyPath = target.keyPath.map { NSString(string: $0).expandingTildeInPath }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-p", String(target.port)]
        if let keyPath { args += ["-i", keyPath] }
        args += ["\(target.user)@\(target.host)", remoteCommand]

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = args
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr

                do { try p.run() } catch {
                    cont.resume(returning: .failure("ssh launch failed: \(error.localizedDescription)"))
                    return
                }
                stdin.fileHandleForWriting.write(Data(remoteScript.utf8))
                stdin.fileHandleForWriting.closeFile()

                let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                p.waitUntilExit()
                deadline.cancel()

                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: .success)
                } else {
                    let tail = (err.isEmpty ? out : err).split(separator: "\n").suffix(6).joined(separator: "\n")
                    cont.resume(returning: .failure(tail.isEmpty ? "exit \(p.terminationStatus)" : String(tail)))
                }
            }
        }
    }
}
