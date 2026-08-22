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
                ttydPort: Int = 8788, lxcID: String? = nil,
                localRepository: URL, remoteCwd: String) async -> Bool {
        guard !running else { return false }
        guard FileManager.default.fileExists(
            atPath: localRepository.appendingPathComponent(".git").path) else {
            steps = [StepStatus(label: "Local repository",
                                state: .failed("Choose a local git repository"))]
            return false
        }
        guard remoteCwd.hasPrefix("/"), remoteCwd.count > 1 else {
            steps = [StepStatus(label: "Remote repository",
                                state: .failed("Remote working directory must be absolute"))]
            return false
        }
        let edgeHost = target.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard edgeHost.hasSuffix(".ts.net") || edgeHost == "localhost" else {
            steps = [StepStatus(label: "Secure Edge hostname",
                                state: .failed("Use the node's full *.ts.net MagicDNS name; one-click deploy refuses IP/cleartext endpoints"))]
            return false
        }
        guard let agentSource = EdgeAgentService.bundledAgentSource() else {
            steps = [StepStatus(label: "Agent source", state: .failed("throttle-agent.mjs missing from app bundle"))]
            return false
        }
        let plan = EdgeAgentService.deploySteps(token: token, httpPort: httpPort,
                                                ttydPort: ttydPort, agentSource: agentSource)
        steps = plan.map { StepStatus(label: $0.label) } + [
            StepStatus(label: "Verify Streamable HTTP"),
            StepStatus(label: "Bundle + clone repository"),
            StepStatus(label: "Route Claude to edge")
        ]
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

        var index = plan.count
        steps[index].state = .running
        let baseURL = EdgeAgentService.remoteURL(host: target.host, port: httpPort)
        let mcp = await EdgeAgentService.verifyMCP(baseURL: baseURL, token: token)
        guard mcp.ok else {
            steps[index].state = .failed(mcp.detail)
            failureDetail = mcp.detail
            return false
        }
        steps[index].state = .done

        index += 1
        steps[index].state = .running
        do {
            try await Self.bundleAndUpload(repository: localRepository,
                                           remoteCwd: remoteCwd,
                                           baseURL: baseURL, token: token)
            steps[index].state = .done
        } catch {
            let message = "repo transfer failed: \(error.localizedDescription)"
            steps[index].state = .failed(message)
            failureDetail = message
            return false
        }

        index += 1
        steps[index].state = .running
        do {
            try Self.installClaudeEdgeRoute(baseURL: baseURL, token: token)
            steps[index].state = .done
        } catch {
            let message = "Claude route unchanged: \(error.localizedDescription)"
            steps[index].state = .failed(message)
            failureDetail = message
            return false
        }
        return true
    }

    // MARK: - Post-deploy gates

    enum DeployError: LocalizedError {
        case git(String)
        case invalidDefinition

        var errorDescription: String? {
            switch self {
            case .git(let message): return message
            case .invalidDefinition: return "could not encode the edge MCP definition"
            }
        }
    }

    /// Definition written only after SSH deploy, MCP verification and repository
    /// transfer have all succeeded. MCPConfigService performs the backup and
    /// atomic read-modify-write of ~/.claude.json.
    nonisolated static func edgeMCPDefinition(baseURL: String, token: String) throws -> Data {
        guard let base = URL(string: baseURL), base.scheme?.lowercased() == "https", base.host != nil
        else { throw DeployError.invalidDefinition }
        let url = base.appendingPathComponent("mcp").absoluteString
        let object: [String: Any] = [
            "type": "http",
            "url": url,
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DeployError.invalidDefinition
        }
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    nonisolated private static func installClaudeEdgeRoute(baseURL: String,
                                                           token: String) throws {
        try MCPConfigService.add(name: "throttle-edge", scope: .user,
                                 defJSON: edgeMCPDefinition(baseURL: baseURL, token: token))
    }

    nonisolated private static func bundleAndUpload(repository: URL, remoteCwd: String,
                                                    baseURL: String, token: String) async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-edge-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        guard let branch = await runGit(["-C", repository.path, "rev-parse",
                                         "--abbrev-ref", "HEAD"]) else {
            throw DeployError.git("could not determine the local git branch")
        }
        guard await runGit(["-C", repository.path, "bundle", "create",
                            bundle.path, "--all"]) != nil else {
            throw DeployError.git("git bundle creation failed")
        }
        _ = try await EdgeAgentService.uploadRepoBundle(
            baseURL: baseURL, token: token, remoteCwd: remoteCwd,
            branch: branch == "HEAD" ? "HEAD" : branch, fileURL: bundle)
    }

    nonisolated private static func runGit(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let value = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: value)
            }
        }
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
        let sshArguments = args

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = sshArguments
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
