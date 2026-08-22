import Foundation
import SwiftUI
import ThrottleShared

/// Holds the connection to a deployed Throttle Edge Agent and its live session list.
///
/// Deliberately SEPARATE from `MultiCockpitModel` (the local cockpit): remote
/// sessions are surfaced in their own panel rather than merged into the local
/// `sessions` array, so this feature can't destabilise the core cockpit. Lifecycle
/// (start/stop/pause/resume) via `EdgeAgentService`; keystroke streaming (the
/// `attach` route) is the iOS companion's job — see `EdgeTerminalView` — not wired
/// into this Mac-side panel.
@MainActor
@Observable
final class RemoteSessionsService {
    static let shared = RemoteSessionsService()

    // Config (persisted). Non-loopback endpoints resolve to HTTPS and the agent
    // itself refuses public binds; the bearer secret is stored in Keychain.
    var host: String { didSet { UserDefaults.standard.set(host, forKey: "throttleEdgeHost") } }
    var port: Int { didSet { UserDefaults.standard.set(port, forKey: "throttleEdgePort") } }
    // Bearer token controls a remote session → Keychain, not UserDefaults.
    var token: String { didSet { KeychainStore.set(token, account: Self.tokenAccount) } }
    private static let tokenAccount = "edgeAgentToken"
    /// Above this, moving a session to the box is a way to lose it. Set below the
    /// 275 MB that was actually killed there, not at it.
    static let transcriptOffloadLimit = 128 * 1024 * 1024

    private(set) var sessions: [EdgeAgentService.RemoteSession] = []
    private(set) var lastVerify: EdgeAgentService.VerifyResult?
    private(set) var polling = false

    private var pollTask: Task<Void, Never>?

    var baseURL: String { EdgeAgentService.remoteURL(host: host, port: port) }
    var isConfigured: Bool { !host.isEmpty && !token.isEmpty }

    private init() {
        host = UserDefaults.standard.string(forKey: "throttleEdgeHost") ?? ""
        let p = UserDefaults.standard.integer(forKey: "throttleEdgePort")
        port = p == 0 ? 8787 : p
        if let k = KeychainStore.get(account: Self.tokenAccount) {
            token = k
        } else if let legacy = UserDefaults.standard.string(forKey: "throttleEdgeToken"), !legacy.isEmpty {
            token = legacy
            KeychainStore.set(legacy, account: Self.tokenAccount)
            UserDefaults.standard.removeObject(forKey: "throttleEdgeToken")
        } else {
            token = ""
        }
    }

    func verify() async {
        guard isConfigured else { lastVerify = .init(ok: false, sessionCount: nil, detail: "Set host + token"); return }
        lastVerify = await EdgeAgentService.verify(baseURL: baseURL, token: token)
    }

    func refresh() async {
        guard isConfigured else { return }
        if let list = try? await EdgeAgentService.sessions(baseURL: baseURL, token: token) {
            // A session that stops appearing has ended on the box, and the row
            // simply vanishing is the worst way to learn it: measured 2026-08-22,
            // a session was OOM-killed there and the only signal was a rail that
            // was one line shorter than before. Announce the disappearance.
            let goneIDs = Set(sessions.map(\.id)).subtracting(list.map(\.id))
            let gone = sessions.filter { goneIDs.contains($0.id) }
            sessions = list
            for session in gone { onSessionVanished?(session) }
            warnOnTranscriptGrowth(list)
        }
    }

    /// Raised when a remote session the app was tracking is no longer reported by
    /// the box. `nil` until the cockpit wires a notification to it.
    var onSessionVanished: ((EdgeAgentService.RemoteSession) -> Void)?

    /// Raised once per session when its transcript grows past a share of the
    /// box's memory. `nil` until the cockpit wires a notification to it.
    var onTranscriptTooLarge: ((EdgeAgentService.RemoteSession, String) -> Void)?
    private var warnedTranscripts: Set<String> = []

    /// Warn while the session can still be saved.
    ///
    /// The guard at offload time only covers sessions being moved. The one that
    /// died on 2026-08-22 was already on the box and grew there: its rollout
    /// reached 275 MB against 2 GB of container memory, and nothing watched it.
    /// The threshold is a fraction of the box's actual memory rather than a fixed
    /// size, because the same transcript is harmless on a large machine.
    private func warnOnTranscriptGrowth(_ list: [EdgeAgentService.RemoteSession]) {
        for session in list {
            guard let bytes = session.transcriptBytes, bytes > 0 else { continue }
            let total = session.memoryTotalBytes ?? (2 * 1024 * 1024 * 1024)
            // An eighth of the box's memory: the session that died was at roughly
            // that mark twenty minutes before the kill, which is enough warning
            // to finish a thought and start fresh.
            guard bytes >= total / 8 else {
                warnedTranscripts.remove(session.id)   // shrank or restarted
                continue
            }
            guard !warnedTranscripts.contains(session.id) else { continue }
            warnedTranscripts.insert(session.id)
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
            onTranscriptTooLarge?(session,
                "Its transcript has reached \(size) on a box with \(cap). A harness holds that in "
                + "memory: a session was killed here at 275 MB on 2026-08-22. Finish the thought and "
                + "start a fresh session — the code stays where it is.")
        }
    }

    /// Poll every 10 s while the panel is visible / feature is on.
    func startPolling() {
        guard isConfigured, !polling else { return }
        polling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil; polling = false }

    /// `runtime` is "claude" or "codex". The box launches a different binary and
    /// resumes with a different flag for each, so the choice cannot be inferred
    /// afterwards — it has to travel with the request.
    func start(project: String?, cwd: String, runtime: String = "claude") async {
        guard isConfigured else { return }
        _ = try? await EdgeAgentService.start(baseURL: baseURL, token: token, project: project,
                                              cwd: cwd, runtime: runtime)
        await refresh()
    }

    func act(_ id: String, _ action: String) async {
        guard isConfigured else { return }
        try? await EdgeAgentService.action(baseURL: baseURL, token: token, id: id, action: action)
        await refresh()
    }

    // MARK: Context transfer (offload a local session WITH its transcript)

    /// A local Claude Code session eligible for offload: the JSONL transcript on
    /// this Mac, identified by its filename stem.
    struct LocalSession: Identifiable, Equatable {
        let id: String          // session id = JSONL filename stem
        let project: String     // decoded-ish project dir name (display only)
        let path: URL
        let sizeBytes: Int
        let modified: Date
    }

    /// Offload progress/result line — shown in the sheet AND the cockpit rail.
    /// Settable by the rail's direct-offload path for its guard messages.
    var offloadStatus: String?

    /// Newest local transcripts across `~/.claude/projects/` (display picker feed).
    /// Pure filesystem scan — no DB dependency, safe to call from the sheet.
    static func recentLocalSessions(limit: Int = 12) -> [LocalSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var all: [LocalSession] = []
        for proj in projects {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: proj, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                all.append(LocalSession(
                    id: f.deletingPathExtension().lastPathComponent,
                    project: proj.lastPathComponent,
                    path: f,
                    sizeBytes: vals?.fileSize ?? 0,
                    modified: vals?.contentModificationDate ?? .distantPast))
            }
        }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// Upload the FULL transcript of `session` to the agent for `remoteCwd`, then
    /// start a remote session resuming it — the whole point: no 10–20-turn context
    /// rebuild on the box. Full copy only; the file is streamed as-is, never trimmed.
    /// Returns the new remote session id, nil on failure (status carries the why).
    @discardableResult
    func offload(_ session: LocalSession, remoteCwd: String, runtime: String? = nil) async -> String? {
        guard isConfigured, !remoteCwd.isEmpty else { return nil }
        // Which step failed matters more than what the error said. "The network
        // connection was lost" is true of an upload, of starting the session, and
        // of the poll that follows — and those have nothing to do with each other.
        // Without the step, the same sentence sent me measuring a 456 MB transfer
        // that turned out to be fine.
        var step = "uploading the transcript"
        offloadStatus = "Uploading \(session.id.prefix(8))… (\(session.sizeBytes / 1024) KB)"
        do {
            let bytes = try await EdgeAgentService.uploadTranscript(
                baseURL: baseURL, token: token, remoteCwd: remoteCwd,
                sessionId: session.id, fileURL: session.path, runtime: runtime)
            offloadStatus = "Uploaded \(bytes / 1024) KB — starting remote session…"
            step = "starting the session on the box"
            let remoteID = try await EdgeAgentService.start(
                baseURL: baseURL, token: token, project: session.project,
                cwd: remoteCwd, resume: session.id, runtime: runtime)
            offloadStatus = "Offloaded — resumed \(session.id.prefix(8)) on the box. It's in the cockpit rail with a REMOTE badge (click to attach)."
            await refresh()
            return remoteID
        } catch {
            offloadStatus = "Offload failed while \(step): \(error.localizedDescription)"
            return nil
        }
    }

    /// One-click offload of a COCKPIT TAB: resolves the tab's transcript on disk
    /// and ships it, defaulting the remote cwd to /root/offload/<project>. This is
    /// the rail decision-menu path — no sheet, no picker. When the local cwd is a
    /// git repo, the CODE goes too (git bundle → clone on the box), so the remote
    /// claude wakes up next to the files it was working on — not an empty dir.
    @discardableResult
    func offloadTab(sessionId: String, localCwd: String, projectName: String,
                    isCodex: Bool = false) async -> String? {
        // The two runtimes keep their transcripts in unrelated places: claude by
        // encoded cwd, codex by date with the timestamp in the filename. Offloading
        // a Codex tab used to look for a claude transcript that never existed, or
        // worse, ship it and ask claude to resume an id it had never seen.
        let path: URL?
        if isCodex {
            path = MissionRuntimeService.codexRolloutURL(id: sessionId)
        } else {
            let enc = MultiCockpitModel.claudeProjectDirName(localCwd)
            path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(enc)/\(sessionId).jsonl")
        }
        let runtimeName = isCodex ? "codex" : "claude"
        guard let path,
              let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            offloadStatus = "No transcript found for this session yet — say something to \(runtimeName) first."
            return nil
        }
        // Refuse to move a transcript the box cannot hold. A harness keeps its
        // rollout in memory, and the edge container has 2 GB: measured
        // 2026-08-22, a 275 MB codex session was OOM-killed there minutes after
        // the file crossed that mark, taking the agent unit down with it. The
        // session simply vanished from the rail, which is the worst possible way
        // to be told. Better to refuse the move than to lose the session on the
        // other side.
        if size >= Self.transcriptOffloadLimit {
            let mb = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            offloadStatus = "This session's transcript is \(mb). The box has 2 GB of memory and would "
                + "run out loading it — a session that size was killed there on 2026-08-22. "
                + "Start a fresh session on the box instead; the code goes over either way."
            return nil
        }

        let remoteCwd = "/root/offload/\(projectName)"
        // Offload moves the conversation and the code. It does NOT move
        // capabilities: MCP servers, plugins and provider credentials belong to
        // the machine they were configured on. A session that could submit to
        // App Store Connect here will discover on the box that it cannot — and
        // discovering it at the moment of a GO, after the work is done, is the
        // expensive way to learn it. Say it up front.
        let missing = Self.capabilitiesLostOnOffload(localCwd: localCwd)
        await uploadRepoIfGit(localCwd: localCwd, remoteCwd: remoteCwd)
        let local = LocalSession(id: sessionId, project: projectName, path: path,
                                 sizeBytes: size, modified: Date())
        let remoteID = await offload(local, remoteCwd: remoteCwd, runtime: runtimeName)
        if remoteID != nil, !missing.isEmpty {
            offloadStatus = (offloadStatus ?? "") + " Note: \(missing) stay on this Mac."
        }
        return remoteID
    }

    /// Best-effort repo transfer: bundle the local git history (full clone, no
    /// untracked files) and let the agent clone it at `remoteCwd`. Every failure
    /// is non-fatal — the transcript offload still proceeds without code.
    private func uploadRepoIfGit(localCwd: String, remoteCwd: String) async {
        let git = URL(fileURLWithPath: localCwd).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: git.path) else { return }
        offloadStatus = "Bundling the repo…"
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        // Carry uncommitted work OUT as well, the way the return trip already
        // carries it back. Without this the handoff was one-directional in a way
        // nobody would expect: leave the Mac mid-edit and the box receives a repo
        // that has never seen those edits, so the session starts by re-doing work
        // that already exists — or worse, contradicts it.
        //
        // `git stash create` builds a commit object from the index and worktree
        // without touching either: the Mac keeps its changes exactly as they are,
        // and the box still receives them under a ref of its own.
        if let sha = await Self.snapshotWorkInProgress(in: localCwd) {
            _ = await Self.runGit(["-C", localCwd, "update-ref", "refs/throttle/wip", sha])
        } else {
            // Nothing in flight, or a previous handoff left a ref behind. Either
            // way the box must not receive a stale one and mistake it for now.
            _ = await Self.runGit(["-C", localCwd, "update-ref", "-d", "refs/throttle/wip"])
        }
        guard let branch = await Self.runGit(["-C", localCwd, "rev-parse", "--abbrev-ref", "HEAD"]),
              await Self.runGit(["-C", localCwd, "bundle", "create", bundle.path, "--all"]) != nil else {
            offloadStatus = "Repo bundling failed — offloading transcript only."
            return
        }
        do {
            offloadStatus = "Uploading the repo bundle…"
            let cloned = try await EdgeAgentService.uploadRepoBundle(
                baseURL: baseURL, token: token, remoteCwd: remoteCwd,
                branch: branch == "HEAD" ? "HEAD" : branch, fileURL: bundle)
            offloadStatus = cloned ? "Repo cloned on the box." : "Box already has files there — kept them."
        } catch {
            offloadStatus = "Repo upload failed (\(error.localizedDescription)) — transcript only."
        }
    }

    /// Bring the box's commits home, into refs nothing else reads.
    ///
    /// Deliberately NOT a merge. The point of this feature is that work is never
    /// lost, and an automatic merge into a working tree that may itself have
    /// moved is a way to lose some. Everything the box has lands under
    /// `refs/throttle-edge/`, where it is safe, inspectable and mergeable at the
    /// user's chosen moment — and the status line says what arrived and how to
    /// reach it, so "safe" does not quietly become "invisible".
    private func retrieveRepo(remoteCwd: String, localCwd: String) async -> String {
        guard FileManager.default.fileExists(atPath: localCwd + "/.git") else {
            return "No git repo here, so no code to bring back."
        }
        offloadStatus = "Fetching the box's commits…"
        do {
            let (bundle, wip) = try await EdgeAgentService.downloadRepoBundle(
                baseURL: baseURL, token: token, remoteCwd: remoteCwd)
            defer { try? FileManager.default.removeItem(at: bundle) }
            // One refspec for everything the bundle carries: branches land under
            // refs/throttle-edge/heads/*, in-flight work under
            // refs/throttle-edge/throttle/wip. No per-ref special-casing, and
            // nothing can collide with a real branch.
            guard await Self.runGit(["-C", localCwd, "fetch", "--quiet", bundle.path,
                                     "+refs/*:refs/throttle-edge/*"]) != nil else {
                return "The box's commits could not be fetched — its work is still on the server."
            }
            let branch = await Self.runGit(["-C", localCwd, "rev-parse", "--abbrev-ref", "HEAD"]) ?? "HEAD"
            let aheadText = await Self.runGit(["-C", localCwd, "rev-list", "--count",
                                               "\(branch)..refs/throttle-edge/heads/\(branch)"])
            let ahead = Int(aheadText ?? "0") ?? 0
            var parts: [String] = []
            if ahead > 0 {
                parts.append("\(ahead) commit\(ahead == 1 ? "" : "s") from the box are in refs/throttle-edge/heads/\(branch) — merge when you're ready.")
            } else {
                parts.append("No new commits on the box.")
            }
            if wip != nil {
                parts.append("It also had uncommitted work — check it with "
                             + "git show --stat refs/throttle-edge/throttle/wip, "
                             + "then apply with git checkout refs/throttle-edge/throttle/wip -- .")
            }
            return parts.joined(separator: " ")
        } catch {
            return "Couldn't fetch the box's code (\(error.localizedDescription)) — it is still on the server."
        }
    }

    /// What this project can do here that it will not be able to do on the box.
    ///
    /// Counted from the MCP servers configured for the project, plus the local
    /// credential-bound work that cannot move at all — signing, notarisation and
    /// App Store submission need the login keychain and the Apple key, and those
    /// are not things to copy onto a server because a session asked.
    static func capabilitiesLostOnOffload(localCwd: String) -> String {
        var lost: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var names = Set((root["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? [])
            if let projects = root["projects"] as? [String: Any],
               let mine = projects[localCwd] as? [String: Any],
               let scoped = mine["mcpServers"] as? [String: Any] {
                names.formUnion(scoped.keys)
            }
            // Present on the box already — see the agent's own MCP config.
            names.subtract(["proxmox", "opnsense-mcp"])
            if !names.isEmpty {
                lost.append("\(names.count) MCP server\(names.count == 1 ? "" : "s")")
            }
        }
        if FileManager.default.fileExists(atPath: localCwd + "/project.yml")
            || !((try? FileManager.default.contentsOfDirectory(atPath: localCwd))?
                .filter { $0.hasSuffix(".xcodeproj") }.isEmpty ?? true) {
            lost.append("signing and App Store submission")
        }
        return lost.joined(separator: " and ")
    }

    /// A commit holding everything not yet committed — modified tracked files
    /// AND new untracked ones — without disturbing the repository.
    ///
    /// `git stash create` was the obvious tool and is the wrong one: it silently
    /// drops untracked files, and it ignores `-u` when asked to include them.
    /// A handoff that loses every newly created file is worse than no handoff,
    /// because the loss is invisible until someone looks for the file.
    ///
    /// Writing through a TEMPORARY index is what makes this safe: `git add -A`
    /// stages into a throwaway file, so the real index and the working tree are
    /// untouched and the user's `git status` reads exactly as before. Ignored
    /// paths stay ignored, so build products and dependencies do not travel.
    static func snapshotWorkInProgress(in cwd: String) async -> String? {
        let index = FileManager.default.temporaryDirectory
            .appendingPathComponent("throttle-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path]
        guard await runGit(["-C", cwd, "read-tree", "HEAD"], env: env) != nil,
              await runGit(["-C", cwd, "add", "-A", "."], env: env) != nil,
              await addDeclaredExtras(in: cwd, env: env),
              let tree = await runGit(["-C", cwd, "write-tree"], env: env),
              !tree.isEmpty
        else { return nil }
        // Identical tree means nothing is in flight; a snapshot would be noise.
        if let head = await runGit(["-C", cwd, "rev-parse", "HEAD^{tree}"]), head == tree {
            return nil
        }
        return await runGit(["-C", cwd, "commit-tree", tree, "-p", "HEAD",
                             "-m", "Throttle handoff: work in progress"])
    }

    /// Carry the ignored files the user says the session needs.
    ///
    /// A handoff that drops `.env`, a local certificate or a fixture leaves the
    /// other machine unable to run anything — the code arrives, the thing that
    /// makes it work does not. Isolated-workspace tools solve this with an
    /// opt-in include list rather than by syncing ignored paths wholesale, which
    /// would drag build products and dependencies across the wire.
    ///
    /// Opt-in, and only opt-in: these paths are ignored precisely because they
    /// are local, and some of them are secrets. Naming a file here is the user
    /// saying "this one may leave this machine".
    ///
    /// Format: `.throttleinclude` at the repository root, one path or glob per
    /// line, `#` for comments.
    private static func addDeclaredExtras(in cwd: String, env: [String: String]) async -> Bool {
        let list = URL(fileURLWithPath: cwd).appendingPathComponent(".throttleinclude")
        guard let text = try? String(contentsOf: list, encoding: .utf8) else { return true }
        let patterns = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for pattern in patterns {
            // Failure is not fatal: a pattern matching nothing is a stale line in
            // a config file, not a reason to abandon the whole handoff.
            _ = await runGit(["-C", cwd, "add", "-f", "--", pattern], env: env)
        }
        return true
    }

    /// Run git off-main; returns trimmed stdout, nil on any failure.
    private nonisolated static func runGit(_ args: [String],
                                          env: [String: String] = [:]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                if !env.isEmpty {
                    var merged = ProcessInfo.processInfo.environment
                    env.forEach { merged[$0.key] = $0.value }
                    p.environment = merged
                }
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { cont.resume(returning: nil); return }
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: s)
            }
        }
    }

    /// Reverse offload: pull the box's current transcript for `remoteID`, drop it
    /// into the LOCAL project dir for `localCwd`, stop the remote session, and
    /// return the new session id to `--resume` locally. Full copy, never trimmed —
    /// the same rule as the outbound direction.
    func bringBack(remoteID: String, localCwd: String) async -> String? {
        guard isConfigured else { return nil }
        offloadStatus = "Bringing session back from the box…"
        do {
            let (sid, data) = try await EdgeAgentService.downloadTranscript(
                baseURL: baseURL, token: token, id: remoteID)
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects/\(MultiCockpitModel.claudeProjectDirName(localCwd))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(sid).jsonl"), options: .atomic)
            // Fetch the code back BEFORE stopping the box: a stopped session is a
            // session whose working tree we can no longer read.
            let repo = await retrieveRepo(
                remoteCwd: "/root/offload/\(URL(fileURLWithPath: localCwd).lastPathComponent)",
                localCwd: localCwd)
            try await EdgeAgentService.action(baseURL: baseURL, token: token, id: remoteID, action: "stop")
            offloadStatus = "Back on the Mac — resuming \(sid.prefix(8)) locally. \(repo)"
            await refresh()
            return sid
        } catch {
            offloadStatus = "Bring back failed: \(error.localizedDescription)"
            return nil
        }
    }
}
