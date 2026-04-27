import Foundation
import GRDB

enum CalibrationEngine {
    /// Anchor calibration: user (or detected warning) tells us they're at observedPercent.
    /// We compute cap = currentTotal / (observedPercent / 100), with a minimum guard.
    static func anchor(in db: Database, kind: WindowKind, observedPercent: Int) throws {
        let total = try WindowCalculator.totalForWindow(in: db, kind: kind)
        let percent = max(1, min(99, observedPercent))
        let cap = Int(Double(total) / (Double(percent) / 100.0))
        guard cap > 0 else { return }
        try DatabaseQueries.upsertCalibration(
            in: db, kind: kind, capTokens: cap, source: "anchor_\(percent)")
    }

    /// Auto calibration: take the rolling max consumption and add a 5% safety margin.
    /// Skips if we already have an anchor or manual cap (those are higher confidence).
    static func auto(in db: Database, kind: WindowKind) throws {
        if let existing = try DatabaseQueries.calibration(in: db, kind: kind),
           existing.source != "auto" {
            return
        }
        let total = try WindowCalculator.totalForWindow(in: db, kind: kind)
        guard total > 0 else { return }
        // Take the larger of (current observed) and (any prior auto cap).
        let prior = try DatabaseQueries.calibration(in: db, kind: kind)?.capTokens ?? 0
        let candidate = Int(Double(total) * 1.05)
        let cap = max(candidate, prior)
        try DatabaseQueries.upsertCalibration(
            in: db, kind: kind, capTokens: cap, source: "auto")
    }

    /// Manual cap: user enters a value in Settings. Highest precedence.
    static func setManual(in db: Database, kind: WindowKind, capTokens: Int) throws {
        guard capTokens > 0 else { return }
        try DatabaseQueries.upsertCalibration(
            in: db, kind: kind, capTokens: capTokens, source: "manual")
    }

    /// Reset clears all calibration so auto can recompute from scratch.
    static func reset(in db: Database, kind: WindowKind) throws {
        try db.execute(sql: "DELETE FROM calibration WHERE window_kind = ?", arguments: [kind.rawValue])
    }
}
