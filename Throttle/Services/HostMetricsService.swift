import Foundation
import Darwin

/// Live host metrics for the cockpit Overview — CPU (overall + per-core), disk
/// free, and network throughput. Memory/swap stays in `SystemMemoryService`
/// (MemoryHealth); this adds the rest. Stateful: CPU% and network B/s are deltas
/// between samples, so the sampler holds the previous reading.
///
/// Doctrine note: these are CONTEXT, not the moat. The UI must render them in
/// graphite — never the orange/red reserved for Claude cap pressure.
@MainActor @Observable
final class HostMetricsService {
    static let shared = HostMetricsService()

    struct Snapshot: Sendable, Equatable {
        var cpuBusy: Double = 0            // 0…1 overall
        var perCore: [Double] = []         // 0…1 each
        var diskFreeBytes: Int64 = 0
        var diskTotalBytes: Int64 = 0
        var netDownBytesPerSec: Double = 0
        var netUpBytesPerSec: Double = 0
        var sampledAt: Date = .distantPast
    }

    private(set) var snapshot = Snapshot()

    // CPU delta state (per-core tick totals from the previous sample).
    private var prevCPUTicks: [(used: UInt64, total: UInt64)] = []
    // Network delta state.
    private var prevNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?

    private init() {}

    /// Take one reading. Cheap synchronous mach/BSD calls — fine on the main actor.
    func sample() {
        var s = Snapshot()
        sampleCPU(into: &s)
        sampleDisk(into: &s)
        sampleNetwork(into: &s)
        s.sampledAt = Date()
        snapshot = s
    }

    // MARK: - CPU (host_processor_info, per-core load ticks → busy delta)

    private func sampleCPU(into s: inout Snapshot) {
        var count = mach_msg_type_number_t(0)
        var info: processor_info_array_t?
        var ncpu: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &ncpu, &info, &count) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let cores = Int(ncpu)
        var cur: [(used: UInt64, total: UInt64)] = []
        cur.reserveCapacity(cores)
        for c in 0..<cores {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let sys  = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            cur.append((used: user + sys + nice, total: user + sys + nice + idle))
        }

        var per: [Double] = []
        if prevCPUTicks.count == cores {
            for c in 0..<cores {
                let du = Double(cur[c].used &- prevCPUTicks[c].used)
                let dt = Double(cur[c].total &- prevCPUTicks[c].total)
                per.append(dt > 0 ? max(0, min(1, du / dt)) : 0)
            }
        }
        prevCPUTicks = cur
        s.perCore = per
        s.cpuBusy = per.isEmpty ? 0 : per.reduce(0, +) / Double(per.count)
    }

    // MARK: - Disk (root volume, "important usage" free is what Finder shows)

    private func sampleDisk(into s: inout Snapshot) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) else { return }
        s.diskFreeBytes = v.volumeAvailableCapacityForImportantUsage ?? 0
        s.diskTotalBytes = Int64(v.volumeTotalCapacity ?? 0)
    }

    // MARK: - Network (getifaddrs, sum physical ifaces, delta → B/s)

    private func sampleNetwork(into s: inout Snapshot) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Physical/active interfaces only — skip loopback + virtual.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            if let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                inBytes += UInt64(data.pointee.ifi_ibytes)
                outBytes += UInt64(data.pointee.ifi_obytes)
            }
        }

        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0.1 {
                s.netDownBytesPerSec = max(0, Double(inBytes &- prev.inBytes) / dt)
                s.netUpBytesPerSec = max(0, Double(outBytes &- prev.outBytes) / dt)
            }
        }
        prevNet = (inBytes, outBytes, now)
    }
}
