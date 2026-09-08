import Darwin
import Foundation

/// Discovery uses a writable transcript held by this tab's process tree. File
/// freshness or a matching cwd alone cannot establish ownership of a conversation.
enum NativeSessionBinding {
    struct Transcript: Sendable, Equatable {
        let id: String
        let url: URL
        let modifiedAt: Date
    }

    static func knownTranscript(
        runtime: AgentRuntime, id: String, cwd: String, codexURLs: [URL]
    ) -> Transcript? {
        guard UUID(uuidString: id) != nil else { return nil }
        let urls: [URL]
        if runtime == .claudeCode {
            let encoded = MultiCockpitModel.claudeProjectDirName(cwd)
            urls = [URL.homeDirectory.appendingPathComponent(".claude/projects/\(encoded)/\(id).jsonl")]
        } else {
            urls = codexURLs.filter { $0.lastPathComponent.contains(id) }
        }
        return urls.lazy.compactMap { transcript(runtime: runtime, cwd: cwd, url: $0) }
            .first { $0.id == id }
    }

    static func ownedTranscript(
        runtime: AgentRuntime, cwd: String, root: NativeProcessIdentity, foregroundPID: pid_t
    ) -> Transcript? {
        guard NativeProcessIdentity.capture(root.pid) == root,
              let foreground = NativeProcessIdentity.capture(foregroundPID),
              foreground.pid != root.pid, foreground.belongs(to: root) else { return nil }
        let pids = SystemMemoryService.subtreePids(rootPids: [root.pid])
        guard pids.count <= 256 else { return nil }
        let processes = pids.compactMap { NativeProcessIdentity.capture($0) }.filter { $0.belongs(to: root) }
        let names = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, executableName(pid: $0.pid)) })
        guard let pid = harnessPID(runtime: runtime, foreground: foreground, processes: processes, names: names),
              let native = processes.first(where: { $0.pid == pid }) else { return nil }
        let paths = writableFiles(pid: pid)
        guard NativeProcessIdentity.capture(pid) == native,
              NativeProcessIdentity.capture(root.pid) == root,
              NativeProcessIdentity.capture(foreground.pid) == foreground else { return nil }
        return uniqueTranscript(runtime: runtime, cwd: cwd, writableURLs: paths)
    }

    /// The native foreground job, or the direct native child of its Node CLI
    /// launcher. Tools and subagents below that native process cannot bind a tab.
    static func harnessPID(
        runtime: AgentRuntime, foreground: NativeProcessIdentity,
        processes: [NativeProcessIdentity], names: [pid_t: String]
    ) -> pid_t? {
        guard let wanted = runtime.executable else { return nil }
        if names[foreground.pid] == wanted { return foreground.pid }
        guard names[foreground.pid] == "node" else { return nil }
        let native = processes.filter { $0.parentPID == foreground.pid && names[$0.pid] == wanted }
        return native.count == 1 ? native.first?.pid : nil
    }

    private static func executableName(pid: pid_t) -> String {
        var name = [UInt8](repeating: 0, count: 128)
        let count = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return "" }
        return String(bytes: name.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    static func uniqueTranscript(
        runtime: AgentRuntime, cwd: String, writableURLs: [URL], home: URL = .homeDirectory
    ) -> Transcript? {
        let root = home.appendingPathComponent(runtime == .codex ? ".codex/sessions" : ".claude/projects")
            .resolvingSymlinksInPath().standardizedFileURL
        let candidates = Set(writableURLs).compactMap { url -> Transcript? in
            let path = url.resolvingSymlinksInPath().standardizedFileURL
            guard path.path.hasPrefix(root.path + "/"), path.pathExtension == "jsonl" else { return nil }
            return transcript(runtime: runtime, cwd: cwd, url: path)
        }
        let identities = Set(candidates.map(\.id))
        guard identities.count == 1 else { return nil }
        return candidates.first
    }

    static func transcript(runtime: AgentRuntime, cwd: String, url: URL) -> Transcript? {
        guard runtime.usesTranscript,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let bytes = (try? file.read(upToCount: 64 * 1024)) ?? Data()
        for line in MissionRuntimeService.newlineSeparatedChunks(bytes).prefix(12) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let metadata: [String: Any]
            let id: String?
            if runtime == .codex {
                guard object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any] else { continue }
                guard codexIsUserSession(payload) else { return nil }
                metadata = payload
                id = payload["id"] as? String
            } else {
                metadata = object
                id = object["sessionId"] as? String
            }
            guard metadata["cwd"] as? String == cwd, let id, UUID(uuidString: id) != nil else { continue }
            return Transcript(id: id, url: url, modifiedAt: modified)
        }
        return nil
    }

    /// Codex can own several rollout writers in one process. The process tree
    /// alone cannot exclude its in-process subagents or internal memory work.
    private static func codexIsUserSession(_ metadata: [String: Any]) -> Bool {
        if let threadSource = metadata["thread_source"], !(threadSource is NSNull) {
            guard threadSource as? String == "user" else { return false }
        }
        // Older rollouts omit source (the native decoder defaults to VSCode).
        // They still need a unique writable descriptor and exact cwd/UUID.
        guard let source = metadata["source"] else { return true }
        if let source = source as? String {
            return ["cli", "vscode", "exec", "mcp"].contains(source)
        }
        guard let source = source as? [String: Any], source.count == 1,
              let custom = source["custom"] as? String, !custom.isEmpty else { return false }
        return true
    }

    static func writableFiles(pid: pid_t) -> [URL] {
        let requested = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard requested > 0, requested <= 4096 * stride else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(requested) / stride + 16)
        let copied = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard copied > 0, copied < descriptors.count * stride else { return [] }
        return descriptors.prefix(Int(copied) / stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout.size(ofValue: info)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(size)) == size,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
            }
            return path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }
        }
    }
}
