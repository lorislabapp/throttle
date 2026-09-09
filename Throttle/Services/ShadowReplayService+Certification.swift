import CryptoKit
import Foundation

extension ShadowReplayService.Ledger {
    /// Exact one-sided 95% upper bound on the false-`verified` rate, given
    /// zero observed false positives: 1 − α^(1/n), not the 3/n
    /// approximation. nil once a false positive exists — then the rate is
    /// measured, not bounded — and nil below `minimumForBound`, where the
    /// bound is arithmetically real but too weak to mean anything.
    var falseVerifiedBound95: Double? {
        let claims = certifiedVerifiedClaims
        guard claims >= Self.minimumForBound, falseVerified == 0 else { return nil }
        return 1 - pow(0.05, 1.0 / Double(claims))
    }

    /// Below this many cases the bound exceeds 25% — reporting it invites
    /// the reader to hear "proven" where the arithmetic says "unknown".
    static let minimumForBound = 10

    /// Cases needed, all passing, to push the 95% bound under `target`.
    /// 299 for 1%, 99 for 3%, 598 for 0.5% — the numbers behind the
    /// golden-set sizing, derived rather than copied.
    static func casesNeeded(forBound target: Double, confidence: Double = 0.95) -> Int {
        guard target > 0, target < 1, confidence > 0, confidence < 1 else { return .max }
        return Int(ceil(log(1 - confidence) / log(1 - target)))
    }

    /// Kept as a SECONDARY signal: it bounds hard failures (escalate/error),
    /// which are the cases the pipeline correctly refused. Useful for sizing
    /// how often the local model gives up, useless as a safety claim — a
    /// wrong `verified` never appears in it.
    var hardFailureBound95: Double? {
        guard replayed >= Self.minimumForBound, hardFailures == 0 else { return nil }
        return 1 - pow(0.05, 1.0 / Double(replayed))
    }

    /// How often repeated runs of the same case reached the same verdict.
    /// nil when nothing has been repeated: no repeats is not full agreement,
    /// it is no evidence either way.
    var repetitionAgreement: Double? {
        let groups = Dictionary(grouping: entries.compactMap { entry -> (String, String)? in
            guard let group = entry.repetitionGroupID else { return nil }
            return (group, entry.status)
        }, by: \.0).mapValues { $0.map(\.1) }.filter { $0.value.count > 1 }
        guard !groups.isEmpty else { return nil }
        let agreeing = groups.values.count { Set($0).count == 1 }
        return Double(agreeing) / Double(groups.count)
    }

    /// Groups whose repeats disagreed, newest first — the cases to look at
    /// before quoting any bound at all.
    var unstableRepetitionGroups: [String] {
        Dictionary(grouping: entries.compactMap { entry -> (String, String)? in
            guard let group = entry.repetitionGroupID else { return nil }
            return (group, entry.status)
        }, by: \.0).mapValues { $0.map(\.1) }
            .filter { $0.value.count > 1 && Set($0.value).count > 1 }
            .keys.sorted()
    }

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

    /// Whether a published bound may be quoted at all. Three things must hold
    /// at once: enough adjudicated claims to make the arithmetic mean anything,
    /// no false verified among them, and repeats that agreed wherever any were
    /// run. Disagreeing repeats are disqualifying rather than discounting: they
    /// say the thing being bounded is not stable enough to bound.
    var boundIsQuotable: (Bool, String) {
        guard certifiedVerifiedClaims >= Self.minimumForBound else {
            return (false, "only \(certifiedVerifiedClaims) adjudicated verified claim(s); "
                + "\(Self.minimumForBound) is the floor")
        }
        guard falseVerified == 0 else {
            return (false, "\(falseVerified) false verified — the rate is measured, not bounded")
        }
        let unstable = unstableRepetitionGroups
        guard unstable.isEmpty else {
            return (false, "\(unstable.count) repeated case(s) disagreed with themselves")
        }
        return (true, "")
    }
}
