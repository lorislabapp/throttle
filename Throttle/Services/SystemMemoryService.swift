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
