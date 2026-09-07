import Darwin
import Foundation

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
        /// macOS purge daemons are actively burning CPU (see `samplePurgeActivityIfDue`).
        var osPurging: Bool = false

        var diskUsedFraction: Double {
            diskTotalBytes > 0 ? min(1, 1 - Double(diskFreeBytes) / Double(diskTotalBytes)) : 0
        }

        /// The volume is close enough to full that ordinary work starts failing.
        ///
        /// Both arms matter: the absolute floor because a single Xcode build can
        /// need several GB of DerivedData in one go, and the ratio because macOS
        /// begins aggressive cache reclamation near the top regardless of the
        /// disk's size. A full disk does not fail loudly — it surfaces as a
        /// mislabelled build error, which costs far more to chase than to prevent.
        var diskTight: Bool {
            guard diskTotalBytes > 0 else { return false }
            return diskFreeBytes < 15_000_000_000 || diskUsedFraction > 0.95
        }

        /// Disk is nearly full AND the OS is thrashing to reclaim it. This is the
        /// state where the whole machine — the embedded terminal included — stalls.
        var diskThrashing: Bool { diskTight && osPurging }
    }

    private(set) var snapshot = Snapshot()

    // CPU delta state (per-core tick totals from the previous sample).
    private var prevCPUTicks: [(used: UInt64, total: UInt64)] = []
    // Network delta state.
    private var prevNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    // Purge-daemon delta state. Sampled on its own slower cadence: unlike the
    // mach/BSD reads above, it forks `ps`, which is too costly for every tick.
    private var prevPurge: (secs: Double, at: Date)?
    private var purgeProbeInFlight = false
    private var osPurging = false

    /// A purge daemon busy at least this fraction of one core, sustained across a
    /// probe interval, counts as "the OS is reclaiming". Below it the daemons are
    /// merely idling and the disk being tight is not yet costing the user anything.
    private static let purgeBusyCoreFraction = 0.25
    private static let purgeProbeInterval: TimeInterval = 10

    private init() {}

    /// Take one reading. Cheap synchronous mach/BSD calls — fine on the main actor.
    func sample() {
        var s = Snapshot()
        sampleCPU(into: &s)
        sampleDisk(into: &s)
        sampleNetwork(into: &s)
        // Carried across, not re-measured: the purge probe forks `ps` and so runs
        // on its own slower cadence via `samplePurgeActivityIfDue`.
        s.osPurging = osPurging
        s.sampledAt = Date()
        snapshot = s
    }

    /// Refresh the purge-daemon signal if its interval has elapsed. Forks `ps`, so
    /// the sweep runs off the main actor and at a tenth of the tick rate; callers
    /// can await this from the same loop that drives `sample()` without stalling it.
    func samplePurgeActivityIfDue() async {
        let now = Date()
        if let prev = prevPurge, now.timeIntervalSince(prev.at) < Self.purgeProbeInterval { return }
        guard !purgeProbeInFlight else { return }
        purgeProbeInFlight = true
        defer { purgeProbeInFlight = false }

        let secs = await Task.detached(priority: .utility) {
            SystemMemoryService.purgeDaemonCPUSeconds()
        }.value
        let probedAt = Date()
        defer { prevPurge = (secs, probedAt) }

        // The first probe only establishes a baseline — there is no rate to report
        // yet, and inventing one would be a number we can't stand behind.
        guard let prev = prevPurge else { return }
        let elapsed = probedAt.timeIntervalSince(prev.at)
        guard elapsed > 0 else { return }
        // Guard against a counter that went backwards (daemon restarted).
        let burned = max(0, secs - prev.secs)
        osPurging = (burned / elapsed) >= Self.purgeBusyCoreFraction
        snapshot.osPurging = osPurging
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
