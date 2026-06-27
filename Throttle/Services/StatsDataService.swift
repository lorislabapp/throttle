import Foundation
import GRDB

/// Read-only computations for the Stats tab. Pulls from `usage_events`,
/// `usage_snapshots`, and `tokopt_savings`. All methods are nonisolated
/// so the views can dispatch them off the main actor when fetching.
enum StatsDataService {
    enum Range: Int, CaseIterable, Identifiable {
        case last24h = 24
        case last7d  = 168
        case last30d = 720
        case all     = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .last24h: return String(localized: "24h")
            case .last7d:  return String(localized: "7d")
            case .last30d: return String(localized: "30d")
            case .all:     return String(localized: "All")
            }
        }
        /// Cutoff seconds-since-epoch. Returns 0 for .all.
        func cutoff(now: Date = Date()) -> Int64 {
            guard rawValue > 0 else { return 0 }
            return Int64(now.timeIntervalSince1970) - Int64(rawValue) * 3600
        }
    }

    // MARK: - Line chart data

    struct LinePoint: Hashable, Sendable {
        let timestamp: Date
        let kind: WindowKind
        let percent: Double  // 0...1; 0 if not calibrated at the time
    }

    static func linePoints(in db: Database, range: Range, now: Date = Date()) throws -> [LinePoint] {
        let cutoff = range.cutoff(now: now)
        let sql: String
        if cutoff > 0 {
            sql = """
            SELECT timestamp_bucket, window_kind, used_tokens, cap_tokens
            FROM usage_snapshots
            WHERE timestamp_bucket >= ?
            ORDER BY timestamp_bucket ASC
            """
        } else {
            sql = """
            SELECT timestamp_bucket, window_kind, used_tokens, cap_tokens
            FROM usage_snapshots
            ORDER BY timestamp_bucket ASC
            """
        }
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap { r in
            guard let kindStr: String = r["window_kind"],
                  let kind = WindowKind(rawValue: kindStr),
                  let bucket: Int64 = r["timestamp_bucket"],
                  let used: Int = r["used_tokens"] else { return nil }
            let cap = r["cap_tokens"] as Int?
            let pct: Double
            if let c = cap, c > 0 {
                pct = min(1.0, Double(used) / Double(c))
            } else {
                pct = 0
            }
            return LinePoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(bucket)),
                kind: kind,
                percent: pct
            )
        }
    }

    // MARK: - Hour-of-day heatmap

    struct HeatCell: Hashable, Sendable {
        let dayOfWeek: Int   // 1 (Sunday) ... 7 (Saturday)
        let hour: Int        // 0...23
        let weightedTokens: Int
    }

    static func heatmap(in db: Database, range: Range, now: Date = Date()) throws -> [HeatCell] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CAST(strftime('%w', datetime(timestamp, 'unixepoch', 'localtime')) AS INTEGER) + 1 AS dow,
                CAST(strftime('%H', datetime(timestamp, 'unixepoch', 'localtime')) AS INTEGER) AS h,
                SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)) AS weighted
            FROM usage_events
            \(where_)
            GROUP BY dow, h
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap {
            guard let d: Int = $0["dow"], let h: Int = $0["h"] else { return nil }
            let w: Int = $0["weighted"] ?? 0
            return HeatCell(dayOfWeek: d, hour: h, weightedTokens: w)
        }
    }

    // MARK: - Model split

    struct ModelSlice: Hashable, Sendable, Identifiable {
        let tier: ModelTier
        let weightedTokens: Int
        var id: ModelTier { tier }
    }

    static func modelSplit(in db: Database, range: Range, now: Date = Date()) throws -> [ModelSlice] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CASE
                    WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)) AS weighted
            FROM usage_events
            \(where_)
            GROUP BY bucket
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        return rows.compactMap {
            guard let b: String = $0["bucket"] else { return nil }
            let w: Int = $0["weighted"] ?? 0
            let tier: ModelTier = {
                switch b {
                case "opus":   return .opus
                case "sonnet": return .sonnet
                case "haiku":  return .haiku
                default:       return .other
                }
            }()
            return ModelSlice(tier: tier, weightedTokens: w)
        }
    }

    // MARK: - Range comparison (Today / Yesterday / This week / Last week)

    /// Sum of weighted tokens between two hour offsets (inclusive of `from`,
    /// exclusive of `to`). `from` and `to` are positive hours-ago values, so
    /// `tokensBetween(from: 0, to: 24)` = last 24 hours, and
    /// `tokensBetween(from: 24, to: 48)` = the 24 hours before that.
    static func tokensBetween(
        in db: Database,
        from hoursAgoStart: Int,
        to hoursAgoEnd: Int,
        now: Date = Date()
    ) throws -> Int {
        precondition(hoursAgoEnd > hoursAgoStart, "end must be older than start")
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(hoursAgoStart) * 3600
        let startTs = nowEpoch - Int64(hoursAgoEnd) * 3600
        let sql = """
            SELECT COALESCE(SUM(input_tokens + output_tokens + cache_create + (cache_read / 10)), 0) AS w
            FROM usage_events
            WHERE timestamp >= ? AND timestamp < ?
            """
        let row = try Row.fetchOne(db, sql: sql, arguments: [startTs, endTs])
        return row?["w"] ?? 0
    }

    // MARK: - Per-project queries (project window)

    /// Sum of weighted tokens for a single project, between two
    /// hour-ago offsets. Per-project filtering uses the same JOIN trick
    /// as `topProjects`: `usage_events.session_id` matches a
    /// `file_state.path` whose directory ends with the project's encoded
    /// name (e.g. `-Users-foo-GitHub-Throttle`). Schema has no `cwd_path`
    /// column so this join is the only way to scope to a project.
    static func tokensForProject(
        in db: Database,
        encodedName: String,
        fromHoursAgo: Int,
        toHoursAgo: Int,
        now: Date = Date()
    ) throws -> Int {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(fromHoursAgo) * 3600
        let startTs = nowEpoch - Int64(toHoursAgo) * 3600
        let _ = encodedName  // see fs.encoded_project filter below
        let sql = """
            SELECT COALESCE(SUM(e.input_tokens + e.output_tokens + e.cache_create + (e.cache_read / 10)), 0) AS w
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ? AND fs.encoded_project = ?
            """
        let row = try Row.fetchOne(db, sql: sql, arguments: [startTs, endTs, encodedName])
        return row?["w"] ?? 0
    }

    /// Active time spent on a project, in seconds. Derived from usage_events
    /// timestamps: consecutive events ≤ `idleGap` apart form one active block;
    /// a larger gap is a break. A block's time is (last − first); a lone event
    /// counts as `minBlock`. Sums all blocks in the window — a real "time spent"
    /// that ignores idle/breaks, unlike wall-clock session uptime.
    static func activeTimeForProject(
        in db: Database,
        encodedName: String,
        fromHoursAgo: Int,
        toHoursAgo: Int,
        idleGap: Int64 = 300,
        minBlock: Int64 = 60,
        now: Date = Date()
    ) throws -> TimeInterval {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(fromHoursAgo) * 3600
        let startTs = nowEpoch - Int64(toHoursAgo) * 3600
        let ts = try Int64.fetchAll(db, sql: """
            SELECT e.timestamp
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ? AND fs.encoded_project = ?
            ORDER BY e.timestamp
            """, arguments: [startTs, endTs, encodedName])
        guard let first = ts.first else { return 0 }
        var total: Int64 = 0
        var blockStart = first
        var prev = first
        for t in ts.dropFirst() {
            if t - prev > idleGap {
                total += max(prev - blockStart, minBlock)
                blockStart = t
            }
            prev = t
        }
        total += max(prev - blockStart, minBlock)
        return TimeInterval(total)
    }

    /// First and last activity timestamps for a project (all-time), as Dates —
    /// powers "working since" and "last active". nil if the project has no events.
    static func activitySpanForProject(in db: Database, encodedName: String) throws -> (first: Date, last: Date)? {
        let row = try Row.fetchOne(db, sql: """
            SELECT MIN(e.timestamp) AS first, MAX(e.timestamp) AS last
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE fs.encoded_project = ?
            """, arguments: [encodedName])
        guard let first = row?["first"] as Int64?, let last = row?["last"] as Int64? else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(first)), Date(timeIntervalSince1970: TimeInterval(last)))
    }

    /// Active seconds from a sorted timestamp list (same block rule as
    /// activeTimeForProject: gaps ≤ idleGap join a block; a lone event = minBlock).
    static func activeSeconds(_ ts: [Int64], idleGap: Int64 = 300, minBlock: Int64 = 60) -> Int64 {
        guard let first = ts.first else { return 0 }
        var total: Int64 = 0, blockStart = first, prev = first
        for t in ts.dropFirst() {
            if t - prev > idleGap { total += max(prev - blockStart, minBlock); blockStart = t }
            prev = t
        }
        return total + max(prev - blockStart, minBlock)
    }

    /// Cross-project work activity: how much real time you actually spend in Claude
    /// Code per day/week, how many projects + sessions you touched this week, and a
    /// per-day breakdown for the chart. "Active" ignores idle/breaks (block rule),
    /// so it's honest time-at-keyboard, not wall-clock.
    struct WorkActivity: Sendable {
        var activeToday: TimeInterval = 0
        var activeWeek: TimeInterval = 0
        var projectsThisWeek: Int = 0
        var sessionsThisWeek: Int = 0
        var daily: [(day: Date, seconds: TimeInterval)] = []          // last 7 local days, oldest first
        var topProjects: [(name: String, seconds: TimeInterval)] = [] // this week, desc
    }

    static func workActivity(in db: Database, now: Date = Date(), days: Int = 7) throws -> WorkActivity {
        var out = WorkActivity()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        guard let weekStart = cal.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return out }
        let weekStartEpoch = Int64(weekStart.timeIntervalSince1970)
        let nowEpoch = Int64(now.timeIntervalSince1970)

        // All events in the window, with project, ordered.
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.timestamp AS ts, fs.encoded_project AS proj, e.session_id AS sid
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ?
            ORDER BY e.timestamp
            """, arguments: [weekStartEpoch, nowEpoch])

        // Bucket timestamps by local day + per project, and tally distinct sets.
        var byDay: [Date: [Int64]] = [:]
        var byProject: [String: [Int64]] = [:]
        var projects = Set<String>(), sessions = Set<String>()
        for r in rows {
            let ts = r["ts"] as Int64
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            byDay[day, default: []].append(ts)
            if let p = r["proj"] as String? { byProject[p, default: []].append(ts); projects.insert(p) }
            if let s = r["sid"] as String? { sessions.insert(s) }
        }

        // Daily breakdown (every day in range, even empty), oldest first.
        for i in 0..<days {
            guard let day = cal.date(byAdding: .day, value: -(days - 1 - i), to: todayStart) else { continue }
            let secs = TimeInterval(activeSeconds(byDay[day]?.sorted() ?? []))
            out.daily.append((day: day, seconds: secs))
        }
        out.activeToday = out.daily.last?.seconds ?? 0
        out.activeWeek = out.daily.reduce(0) { $0 + $1.seconds }
        out.projectsThisWeek = projects.count
        out.sessionsThisWeek = sessions.count
        out.topProjects = byProject
            .map { (name: displayName(forEncoded: $0.key), seconds: TimeInterval(activeSeconds($0.value.sorted()))) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6).map { $0 }
        return out
    }

    /// Same active-time analysis over an ARBITRARY date range [from, to) — powers
    /// the time-tracking day / custom-range picker. Daily buckets span the range;
    /// `activeWeek` here is the range total (idle gaps >5 min excluded, like above).
    static func workActivity(in db: Database, from: Date, to: Date) throws -> WorkActivity {
        var out = WorkActivity()
        let cal = Calendar.current
        let startEpoch = Int64(from.timeIntervalSince1970)
        let endEpoch = Int64(to.timeIntervalSince1970)
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.timestamp AS ts, fs.encoded_project AS proj, e.session_id AS sid
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ?
            ORDER BY e.timestamp
            """, arguments: [startEpoch, endEpoch])

        var byDay: [Date: [Int64]] = [:], byProject: [String: [Int64]] = [:]
        var projects = Set<String>(), sessions = Set<String>()
        for r in rows {
            let ts = r["ts"] as Int64
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
            byDay[day, default: []].append(ts)
            if let p = r["proj"] as String? { byProject[p, default: []].append(ts); projects.insert(p) }
            if let s = r["sid"] as String? { sessions.insert(s) }
        }

        let startDay = cal.startOfDay(for: from)
        let dayCount = max(1, (cal.dateComponents([.day], from: startDay, to: cal.startOfDay(for: to)).day ?? 0) + 1)
        for i in 0..<dayCount {
            guard let day = cal.date(byAdding: .day, value: i, to: startDay) else { continue }
            out.daily.append((day: day, seconds: TimeInterval(activeSeconds(byDay[day]?.sorted() ?? []))))
        }
        out.activeToday = out.daily.last?.seconds ?? 0
        out.activeWeek = out.daily.reduce(0) { $0 + $1.seconds }
        out.projectsThisWeek = projects.count
        out.sessionsThisWeek = sessions.count
        out.topProjects = byProject
            .map { (name: displayName(forEncoded: $0.key), seconds: TimeInterval(activeSeconds($0.value.sorted()))) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(8).map { $0 }
        return out
    }

    /// Encoded project dir → human display name (last path component), best-effort.
    private static func displayName(forEncoded encoded: String) -> String {
        if let path = ProjectsService.decodePath(encoded) {
            return (path as NSString).lastPathComponent
        }
        return (encoded as NSString).lastPathComponent
    }

    /// Deterministic workflow milestones for a project from its transcripts —
    /// `git commit` (objective "done" markers) and test-runner invocations (verify
    /// gates). We count them WITHOUT inferring pass/fail (golden rule): cost ÷ count
    /// is an honest "cost per committed unit / per verify run", not a quality claim.
    struct WorkflowCounts: Sendable { var commits = 0; var verifyRuns = 0 }

    nonisolated(unsafe) private static let verifyRegex = try! NSRegularExpression(
        pattern: #"\b(pytest|jest|vitest|mocha|rspec|phpunit|deepeval|(cargo|go|swift|dotnet)\s+test|xcodebuild\s+[^\n]*\btest\b|npm\s+(run\s+)?test|yarn\s+test|pnpm\s+test|make\s+test)\b"#,
        options: [.caseInsensitive])

    static func workflowCounts(encodedName: String, windowDays: Int = 30) -> WorkflowCounts {
        var c = WorkflowCounts()
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(encodedName)")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return c }
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        for name in entries where name.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: path)
            if let mt = attrs?[.modificationDate] as? Date, mt < cutoff { continue }
            guard let data = fm.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("\"Bash\"") || line.contains("tool_use") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let blocks = msg["content"] as? [[String: Any]] else { continue }
                for b in blocks where (b["type"] as? String) == "tool_use" && (b["name"] as? String) == "Bash" {
                    guard let cmd = (b["input"] as? [String: Any])?["command"] as? String else { continue }
                    if cmd.range(of: #"\bgit\s+commit\b"#, options: .regularExpression) != nil { c.commits += 1 }
                    let r = NSRange(cmd.startIndex..., in: cmd)
                    if verifyRegex.firstMatch(in: cmd, range: r) != nil { c.verifyRuns += 1 }
                }
            }
        }
        return c
    }

    /// (sessionCount, avgTokensPerSession) for a project.
    static func sessionsForProject(
        in db: Database,
        encodedName: String,
        fromHoursAgo: Int,
        toHoursAgo: Int,
        now: Date = Date()
    ) throws -> (Int, Int) {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(fromHoursAgo) * 3600
        let startTs = nowEpoch - Int64(toHoursAgo) * 3600
        let _ = encodedName  // see fs.encoded_project filter below
        let sql = """
            SELECT
                COUNT(DISTINCT e.session_id) AS sessions,
                COALESCE(SUM(e.input_tokens + e.output_tokens + e.cache_create + (e.cache_read / 10)), 0) AS total
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ? AND fs.encoded_project = ?
            """
        let row = try Row.fetchOne(db, sql: sql, arguments: [startTs, endTs, encodedName])
        let sessions: Int = row?["sessions"] ?? 0
        let total: Int = row?["total"] ?? 0
        let avg = sessions > 0 ? total / sessions : 0
        return (sessions, avg)
    }

    /// Model split for a project: array of (label, share 0...1).
    static func modelSplitForProject(
        in db: Database,
        encodedName: String,
        fromHoursAgo: Int,
        toHoursAgo: Int,
        now: Date = Date()
    ) throws -> [(String, Double)] {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(fromHoursAgo) * 3600
        let startTs = nowEpoch - Int64(toHoursAgo) * 3600
        let _ = encodedName  // see fs.encoded_project filter below
        let sql = """
            SELECT
                CASE
                    WHEN lower(e.model) LIKE '%opus%'   THEN 'Opus'
                    WHEN lower(e.model) LIKE '%sonnet%' THEN 'Sonnet'
                    WHEN lower(e.model) LIKE '%haiku%'  THEN 'Haiku'
                    ELSE 'Other'
                END AS bucket,
                SUM(e.input_tokens + e.output_tokens + e.cache_create + (e.cache_read / 10)) AS w
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ? AND fs.encoded_project = ?
            GROUP BY bucket
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [startTs, endTs, encodedName])
        let total: Int = rows.reduce(0) { $0 + ($1["w"] ?? 0) }
        guard total > 0 else { return [] }
        return rows.compactMap { r in
            guard let label: String = r["bucket"], let w: Int = r["w"] else { return nil }
            return (label, Double(w) / Double(total))
        }.sorted { $0.1 > $1.1 }
    }

    /// Cost in EUR for a single project.
    static func costForProject(
        in db: Database,
        encodedName: String,
        fromHoursAgo: Int,
        toHoursAgo: Int,
        now: Date = Date()
    ) throws -> Double {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        let endTs = nowEpoch - Int64(fromHoursAgo) * 3600
        let startTs = nowEpoch - Int64(toHoursAgo) * 3600
        let _ = encodedName  // see fs.encoded_project filter below
        let sql = """
            SELECT
                CASE
                    WHEN lower(e.model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(e.model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(e.model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(e.input_tokens) AS i,
                SUM(e.output_tokens) AS o,
                SUM(e.cache_create) AS cc,
                SUM(e.cache_read) AS cr
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            WHERE e.timestamp >= ? AND e.timestamp < ? AND fs.encoded_project = ?
            GROUP BY bucket
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [startTs, endTs, encodedName])
        let usdToEur: Double = 0.93
        var totalUsd: Double = 0
        for row in rows {
            let bucket: String = row["bucket"] ?? ""
            let i: Int = row["i"] ?? 0
            let o: Int = row["o"] ?? 0
            let cc: Int = row["cc"] ?? 0
            let cr: Int = row["cr"] ?? 0
            let (inRate, outRate): (Double, Double)
            switch bucket {
            case "opus":   (inRate, outRate) = (15, 75)
            case "sonnet": (inRate, outRate) = (3, 15)
            case "haiku":  (inRate, outRate) = (0.80, 4)
            default:       (inRate, outRate) = (3, 15)
            }
            let perMillion = 1_000_000.0
            totalUsd += Double(i) / perMillion * inRate
            totalUsd += Double(o) / perMillion * outRate
            totalUsd += Double(cc) / perMillion * inRate * 1.25
            totalUsd += Double(cr) / perMillion * inRate * 0.10
        }
        return totalUsd * usdToEur
    }

    // MARK: - Cost extrapolation

    /// Approximate API cost for the given range, in EUR.
    /// Anthropic public prices (April 2026, USD per million tokens; we apply
    /// a flat 0.93 EUR/USD conversion to keep this offline-friendly):
    ///   Opus:   $15 input / $75 output
    ///   Sonnet:  $3 input / $15 output
    ///   Haiku:   $0.80 input / $4 output
    /// Cache reads are billed at ~10% of input rate, cache writes at 125%.
    static func extrapolatedCostEUR(in db: Database, range: Range, now: Date = Date()) throws -> Double {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE timestamp >= ?" : ""
        let sql = """
            SELECT
                CASE
                    WHEN lower(model) LIKE '%fable%' OR lower(model) LIKE '%mythos%' THEN 'fable'
                    WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                    WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                    WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                    ELSE 'other'
                END AS bucket,
                SUM(input_tokens) AS i,
                SUM(output_tokens) AS o,
                SUM(cache_create) AS cc,
                SUM(cache_read) AS cr
            FROM usage_events
            \(where_)
            GROUP BY bucket
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)
        let usdToEur: Double = 0.93
        var totalUsd: Double = 0
        for row in rows {
            let bucket: String = row["bucket"] ?? ""
            let i: Int = row["i"] ?? 0
            let o: Int = row["o"] ?? 0
            let cc: Int = row["cc"] ?? 0
            let cr: Int = row["cr"] ?? 0
            let (inRate, outRate): (Double, Double)
            switch bucket {   // official USD/MTok rates, refreshed 2026-06-11
            case "fable":  (inRate, outRate) = (10, 50)
            case "opus":   (inRate, outRate) = (5, 25)
            case "sonnet": (inRate, outRate) = (3, 15)
            case "haiku":  (inRate, outRate) = (1, 5)
            default:       (inRate, outRate) = (3, 15)  // unknown → assume Sonnet rates
            }
            let perMillion = 1_000_000.0
            let input = Double(i) / perMillion * inRate
            let output = Double(o) / perMillion * outRate
            let cacheWrite = Double(cc) / perMillion * inRate * 1.25
            let cacheRead = Double(cr) / perMillion * inRate * 0.10
            totalUsd += input + output + cacheWrite + cacheRead
        }
        return totalUsd * usdToEur
    }

    /// Recoverable Miss Cost — EUR you burned re-writing a prompt cache that SHOULD
    /// have still been warm. Within a session, a large `cache_create` <5 min after
    /// the previous turn means the cached prefix got busted (a changing prefix, a
    /// model swap, a dynamic injection): those tokens billed at the 1.25× write rate
    /// when a warm cache would have billed them at the 0.10× read rate. The saving
    /// is the 1.15× delta. Conservative on purpose (golden rule — never overstate):
    /// only counts writes >10 k tokens within the 5-min TTL, so normal incremental
    /// writes don't inflate it. Returns (eur, tokens). 0 when the cache is healthy.
    static func recoverableMissCostEUR(in db: Database, days: Int = 7, now: Date = Date()) throws -> (eur: Double, tokens: Int) {
        let cutoff = Int(now.timeIntervalSince1970) - days * 86_400
        // Per-session sequential gap via window function; flag big writes within TTL.
        let sql = """
            WITH seq AS (
                SELECT
                    CASE
                        WHEN lower(model) LIKE '%fable%' OR lower(model) LIKE '%mythos%' THEN 'fable'
                        WHEN lower(model) LIKE '%opus%'   THEN 'opus'
                        WHEN lower(model) LIKE '%sonnet%' THEN 'sonnet'
                        WHEN lower(model) LIKE '%haiku%'  THEN 'haiku'
                        ELSE 'other'
                    END AS bucket,
                    cache_create AS cc,
                    timestamp - LAG(timestamp) OVER (PARTITION BY session_id ORDER BY timestamp) AS gap
                FROM usage_events
                WHERE timestamp >= ?
            )
            SELECT bucket, SUM(cc) AS recoverable
            FROM seq
            WHERE gap IS NOT NULL AND gap >= 0 AND gap < 300 AND cc > 10000
            GROUP BY bucket
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [cutoff])
        let perMillion = 1_000_000.0, usdToEur = 0.93
        var usd: Double = 0, tokens = 0
        for row in rows {
            let bucket: String = row["bucket"] ?? ""
            let cc: Int = row["recoverable"] ?? 0
            let inRate: Double
            switch bucket {
            case "fable":  inRate = 10
            case "opus":   inRate = 5
            case "sonnet": inRate = 3
            case "haiku":  inRate = 1
            default:       inRate = 3
            }
            usd += Double(cc) / perMillion * inRate * 1.15   // write 1.25× → read 0.10× delta
            tokens += cc
        }
        return (usd * usdToEur, tokens)
    }

    // MARK: - Per-project breakdown

    struct ProjectSlice: Hashable, Sendable, Identifiable {
        let projectName: String   // last path component, e.g. "Throttle"
        let projectPath: String   // decoded full path, e.g. "/Users/kevin/GitHub/Throttle"
        let weightedTokens: Int
        var id: String { projectPath }
    }

    /// Top N projects by token spend in the given range. Joins
    /// `usage_events` by `session_id` to `file_state` via JSONL path,
    /// filters out subagent transcripts (they live under
    /// `<project>/<session>/subagents/agent-*.jsonl` and would otherwise
    /// pollute the grouping), then aggregates by the encoded project dir
    /// — the segment matching `~/.claude/projects/-X-Y-Z/`.
    static func topProjects(in db: Database, range: Range, limit: Int = 5, now: Date = Date()) throws -> [ProjectSlice] {
        let cutoff = range.cutoff(now: now)
        let where_ = cutoff > 0 ? "WHERE e.timestamp >= ?" : ""
        let sql = """
            SELECT fs.path AS path,
                   SUM(e.input_tokens + e.output_tokens + e.cache_create + (e.cache_read / 10)) AS weighted
            FROM usage_events e
            JOIN file_state fs ON fs.session_id = e.session_id
            \(where_)
            AND fs.path NOT LIKE '%/subagents/%'
            GROUP BY fs.path
            """
        let rows = cutoff > 0
            ? try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            : try Row.fetchAll(db, sql: sql)

        // Aggregate by encoded project directory. The path layout is
        //   ~/.claude/projects/-Users-foo-GitHub-Bar/<session>.jsonl
        // so the project dir = parent of the .jsonl. We extract that
        // and key the aggregate on it, decoded to the real filesystem
        // path for display.
        var byProject: [String: Int] = [:]
        for row in rows {
            guard let path: String = row["path"] else { continue }
            let weighted: Int = row["weighted"] ?? 0
            let dir = (path as NSString).deletingLastPathComponent
            byProject[dir, default: 0] += weighted
        }

        let slices = byProject.map { (encoded, tokens) -> ProjectSlice in
            let decoded = decodeClaudeProjectPath(encoded)
            let name = (decoded as NSString).lastPathComponent
            return ProjectSlice(
                projectName: name.isEmpty ? "(unknown)" : name,
                projectPath: decoded,
                weightedTokens: tokens
            )
        }
        return slices
            .sorted { $0.weightedTokens > $1.weightedTokens }
            .prefix(limit)
            .map { $0 }
    }

    /// Convert Claude Code's encoded project directory back to its
    /// real filesystem path. Format:
    ///   /Users/kevin/.claude/projects/-Users-kevin-GitHub-Throttle
    /// → /Users/kevin/GitHub/Throttle
    /// Defers to ProjectsService.decodePath, which tries multiple
    /// candidate path partitions and prefers the one that exists on
    /// disk — disambiguates real-world cases like `Lumen-for-Frigate`
    /// where the naive replace would produce `/Lumen/for/Frigate`.
    private static func decodeClaudeProjectPath(_ projectsSubdir: String) -> String {
        let encoded = (projectsSubdir as NSString).lastPathComponent
        return ProjectsService.decodePath(encoded) ?? projectsSubdir
    }

    // MARK: - Hook savings

    /// Realized, byte-measured savings grouped by the hook that produced them
    /// (e.g. `tokopt-bash`). EXACT: a true before/after on the same tool output.
    /// `days`-window, most-saved first. Drives the per-technique Savings Ledger.
    struct HookSaving: Sendable, Identifiable {
        var id: String { hook }
        let hook: String
        let bytes: Int       // exact: Σ max(0, baseline − actual)
        let records: Int     // how many hook fires contributed
    }

    static func savedByHook(in db: Database, days: Int = 7, now: Date = Date()) throws -> [HookSaving] {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 24 * 3600
        let rows = try Row.fetchAll(db, sql: """
            SELECT hook,
                   COALESCE(SUM(MAX(0, baseline_bytes - actual_bytes)), 0) AS bytes,
                   COUNT(*) AS n
            FROM tokopt_savings
            WHERE timestamp >= ?
            GROUP BY hook
            HAVING bytes > 0
            ORDER BY bytes DESC
            """, arguments: [cutoff])
        return rows.map { HookSaving(hook: $0["hook"] ?? "?", bytes: $0["bytes"] ?? 0, records: $0["n"] ?? 0) }
    }

    static func savedBytesThisWeek(in db: Database, now: Date = Date()) throws -> Int {
        let cutoff = Int64(now.timeIntervalSince1970) - 7 * 24 * 3600
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(MAX(0, baseline_bytes - actual_bytes)), 0) AS saved
            FROM tokopt_savings
            WHERE timestamp >= ?
            """, arguments: [cutoff])
        return row?["saved"] ?? 0
    }

    /// Approximate token savings (4 bytes per token average for English-heavy logs).
    static func savedTokensThisWeek(in db: Database, now: Date = Date()) throws -> Int {
        let bytes = try savedBytesThisWeek(in: db, now: now)
        return bytes / 4
    }

    /// Per-day token savings for the last `days` days, oldest-first. Days
    /// with no hook activity return 0. Used to drive the meter's sparkline
    /// next to the "tokens saved" hero card — gives the number a sense of
    /// trend without requiring the user to dig into Stats.
    static func savedTokensByDay(
        in db: Database,
        days: Int = 7,
        now: Date = Date()
    ) throws -> [Int] {
        let cal = Calendar(identifier: .gregorian)
        let startOfToday = cal.startOfDay(for: now)
        guard let startCutoff = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday) else {
            return Array(repeating: 0, count: days)
        }
        let cutoff = Int64(startCutoff.timeIntervalSince1970)
        let sql = """
            SELECT
                CAST(strftime('%s', date(timestamp, 'unixepoch', 'localtime')) AS INTEGER) AS day_start,
                SUM(MAX(0, baseline_bytes - actual_bytes)) AS saved
            FROM tokopt_savings
            WHERE timestamp >= ?
            GROUP BY day_start
            ORDER BY day_start ASC
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [cutoff])

        // Index by day-start epoch for fast lookup, then walk the requested
        // window so missing days slot in as zero.
        var byDayStart: [Int64: Int] = [:]
        for r in rows {
            let key: Int64 = r["day_start"] ?? 0
            let saved: Int = r["saved"] ?? 0
            byDayStart[key] = saved / 4
        }
        return (0..<days).compactMap { offset -> Int? in
            guard let day = cal.date(byAdding: .day, value: offset - (days - 1), to: startOfToday) else { return nil }
            // strftime('%s', date(...)) in SQLite localtime returns UTC seconds
            // for the local-day boundary; mirror with timeIntervalSince1970.
            return byDayStart[Int64(day.timeIntervalSince1970)] ?? 0
        }
    }
}
