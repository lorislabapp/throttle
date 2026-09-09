import CryptoKit
import Foundation

extension ShadowReplayService.Ledger {
    /// Identity of the frozen certification set: which cases, against which
    /// exact sources. Any addition, removal or source change gives a new
    /// digest, so a bound is always quoted with the set it was computed on.
    /// nil while no certification case exists — nothing is frozen yet.
    var certificationCaseSetSHA256: String? {
        let cases = entries.filter(\.isCertification)
        guard !cases.isEmpty else { return nil }
        let canonical = cases.map { $0.sessionId + "\u{0}" + String($0.ts) + "\u{0}" + ($0.sourceSHA256 ?? "") }
            .sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
