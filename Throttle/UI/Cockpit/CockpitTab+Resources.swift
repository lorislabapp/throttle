import AppKit
import SwiftTerm
import SwiftUI

extension CockpitTab {

    enum ResourceState: String {
        case healthy
        case constrained
        case critical
    }

    struct ResourceEnvelope: Equatable {
        let warningBytes: UInt64
        let criticalBytes: UInt64
        let cpuWarningPercent: Double
    }

    /// Hardware-aware defaults, overridable without changing the user's agent
    /// configuration. These are sampled application guards, not kernel quotas.
    static var resourceEnvelope: ResourceEnvelope {
        let physical = ProcessInfo.processInfo.physicalMemory
        let defaultWarning = max(1_500_000_000, min(4_000_000_000, physical / 4))
        let defaultCritical = max(defaultWarning + 500_000_000, min(6_000_000_000, physical * 3 / 8))
        let defaults = UserDefaults.standard
        let warningMB = defaults.integer(forKey: "throttleSessionMemoryWarningMB")
        let criticalMB = defaults.integer(forKey: "throttleSessionMemoryCriticalMB")
        return ResourceEnvelope(
            warningBytes: warningMB > 0 ? UInt64(warningMB) * 1_048_576 : defaultWarning,
            criticalBytes: criticalMB > 0 ? UInt64(criticalMB) * 1_048_576 : defaultCritical,
            cpuWarningPercent: 250
        )
    }

    var resourceState: ResourceState {
        let envelope = Self.resourceEnvelope
        if ramBytes >= envelope.criticalBytes { return .critical }
        if ramBytes >= envelope.warningBytes || consecutiveHighCPUSamples >= 3 { return .constrained }
        return .healthy
    }

    var resourceReason: String? {
        let envelope = Self.resourceEnvelope
        if ramBytes >= envelope.criticalBytes {
            return "RAM reached the sampled critical envelope"
        }
        if ramBytes >= envelope.warningBytes { return "RAM is above the sampled warning envelope" }
        if consecutiveHighCPUSamples >= 3 { return "CPU stayed above 250% for three samples" }
        return nil
    }

    func recordCPUPercent(_ value: Double) {
        cpuPercent = max(0, value)
        consecutiveHighCPUSamples = value >= Self.resourceEnvelope.cpuWarningPercent
            ? consecutiveHighCPUSamples + 1
            : 0
    }
}
