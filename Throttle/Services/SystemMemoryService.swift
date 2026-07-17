import Foundation
import Darwin

/// Live system-memory health — the missing half of the "keep going?" decision.
/// Token headroom says nothing about whether the Mac can take another `claude`
/// session; on a 16 GB machine deep in swap, "open another tab" is often the
/// wrong call even with tokens to spare. Read-only, no entitlements: mach VM
/// stats + `vm.swapusage` + the kernel pressure level + a `ps` sweep for the
/// running `claude` processes. Scoped to the Claude-Code decision — NOT a
/// general system monitor.
struct MemoryHealth: Sendable, Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64        // active + wired + compressed (≈ Activity Monitor "used")
    let swapUsedBytes: UInt64
    let pressureLevel: Int       // 1 normal · 2 warning · 4 critical (kernel)
    let claudeCount: Int
    let claudeRSSBytes: UInt64

    var usedFraction: Double { totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0 }
    /// "Should I think twice before opening another session?"
    var underPressure: Bool { pressureLevel >= 2 || swapUsedBytes > 4_000_000_000 }
    /// "Opening another session will make things worse."
    var critical: Bool { pressureLevel >= 4 || swapUsedBytes > 16_000_000_000 }

    static let unknown = MemoryHealth(totalBytes: 0, usedBytes: 0, swapUsedBytes: 0,
                                      pressureLevel: 1, claudeCount: 0, claudeRSSBytes: 0)
}

enum SystemMemoryService {

    static func sample() -> MemoryHealth {
        let cl = claudeProcesses()
        return MemoryHealth(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            usedBytes: usedMemory(),
            swapUsedBytes: swapUsed(),
            pressureLevel: pressureLevel(),
            claudeCount: cl.count,
            claudeRSSBytes: cl.rss
        )
    }

    // MARK: - Mach VM stats

    private static func usedMemory() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize == 0 ? 16384 : pageSize)
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    // MARK: - sysctl

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage.xsu_used : 0
    }

    private static func pressureLevel() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.stride
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 1
    }

    /// Resident memory of each process SUBTREE rooted at the given pids (shell →
    /// claude → node descendants). One `ps` sweep, then BFS per root. Used for
    /// real per-session RAM in the multi-cockpit.
    static func subtreeRSS(rootPids: [pid_t]) -> [pid_t: UInt64] {
        guard !rootPids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var children: [pid_t: [pid_t]] = [:]
        var rssKB: [pid_t: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]), let rss = UInt64(f[2]) else { continue }
            children[ppid, default: []].append(pid)
            rssKB[pid] = rss
        }
        var out: [pid_t: UInt64] = [:]
        for root in rootPids {
            var total: UInt64 = 0
            var stack = [root]
            while let cur = stack.popLast() {
                total += (rssKB[cur] ?? 0)
                if let kids = children[cur] { stack.append(contentsOf: kids) }
            }
            out[root] = total * 1024
        }
        return out
    }

    /// Cumulative CPU-seconds burned by each subtree (root + descendants), one ps sweep.
    ///
    /// Sample twice and diff to learn whether a subtree is working RIGHT NOW. Do not
    /// reach for `ps %cpu` instead: on macOS that is an average over the process's
    /// whole lifetime, so it stays high long after a process goes quiet and reads low
    /// for a compile that just started.
    static func subtreeCPUSeconds(rootPids: [pid_t]) -> [pid_t: Double] {
        guard !rootPids.isEmpty else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,time="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var children: [pid_t: [pid_t]] = [:]
        var cpu: [pid_t: Double] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]),
                  let secs = parseCPUTime(String(f[2])) else { continue }
            children[ppid, default: []].append(pid)
            cpu[pid] = secs
        }
        var out: [pid_t: Double] = [:]
        for root in rootPids {
            var total = 0.0
            var stack = [root]
            while let cur = stack.popLast() {
                total += (cpu[cur] ?? 0)
                if let kids = children[cur] { stack.append(contentsOf: kids) }
            }
            out[root] = total
        }
        return out
    }

    /// ps TIME: `[DD-]HH:MM:SS.ss`, `MM:SS.ss`, or `SS.ss`. Returns seconds.
    static func parseCPUTime(_ raw: String) -> Double? {
        var rest = raw
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[rest.startIndex..<dash]) else { return nil }
            days = d
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var secs = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            secs = secs * 60 + v
        }
        return days * 86_400 + secs
    }

    /// All PIDs in a process subtree (root + every descendant), via one ps sweep.
    static func subtreePids(rootPids: [pid_t]) -> [pid_t] {
        guard !rootPids.isEmpty else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return rootPids }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return rootPids }
        var children: [pid_t: [pid_t]] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count == 2, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        var out: [pid_t] = []
        for root in rootPids {
            var stack = [root]
            while let cur = stack.popLast() {
                out.append(cur)
                if let kids = children[cur] { stack.append(contentsOf: kids) }
            }
        }
        return out
    }

    /// Guaranteed teardown of a session's process subtree (shell → claude → node):
    /// SIGTERM the whole tree (deepest first so a parent can't respawn a child),
    /// then SIGKILL any survivor after a grace period. This is what actually frees
    /// the RAM — a cooperative Ctrl-D can't kill a busy claude TUI, which is how
    /// hibernate was orphaning subtrees. Safe no-op for pid ≤ 1.
    static func killSubtree(rootPid: pid_t, grace: TimeInterval = 1.5) {
        guard rootPid > 1 else { return }
        let term = subtreePids(rootPids: [rootPid])
        for pid in term.reversed() where pid > 1 { kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            let survivors = subtreePids(rootPids: [rootPid])
            for pid in survivors.reversed() where pid > 1 { kill(pid, SIGKILL) }
        }
    }

    /// Freeze (SIGSTOP) or resume (SIGCONT) a session's whole subtree — a
    /// reversible pause that stops token burn without killing state. User-
    /// triggered only (the circuit-breaker's safe half). Deepest-first on stop so
    /// a parent can't step a child past the freeze; shallowest-first on resume.
    static func signalSubtree(rootPid: pid_t, signal sig: Int32) {
        guard rootPid > 1 else { return }
        let pids = subtreePids(rootPids: [rootPid])
        let ordered = (sig == SIGSTOP) ? pids.reversed() : Array(pids)
        for pid in ordered where pid > 1 { kill(pid, sig) }
    }

    // MARK: - Running claude sessions

    /// Sum RSS of processes whose executable name is exactly `claude` (the CLI).
    /// Best-effort: a `ps` sweep, excluding our own app. RSS undercounts when the
    /// kernel has swapped/compressed pages, but the count + the pressure/swap
    /// signals above carry the decision.
    private static func claudeProcesses() -> (count: Int, rss: UInt64) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return (0, 0) }

        var count = 0
        var rssKB: UInt64 = 0
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            let comm = trimmed[trimmed.index(after: sp)...].trimmingCharacters(in: .whitespaces)
            guard comm == "claude" || comm.hasSuffix("/claude") else { continue }
            if let kb = UInt64(trimmed[..<sp]) { rssKB += kb; count += 1 }
        }
        return (count, rssKB * 1024)
    }
}
