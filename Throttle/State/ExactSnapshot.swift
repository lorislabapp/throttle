import Foundation

/// Exact-mode usage snapshot, fetched directly from claude.ai's
/// `/api/organizations/{org_id}/usage` private endpoint.
///
/// Endpoint shape (all utilizations are integer percentages 0-100):
///
///     {
///       "five_hour":         { "utilization": 25, "resets_at": "2026-04-28T19:00:00..." },
///       "seven_day":         { "utilization":  3, "resets_at": "2026-05-05T14:00:00..." },
///       "seven_day_sonnet":  { "utilization":  0, "resets_at": null }
///     }
///
/// `resets_at` is the wall-clock UTC moment the rolling window expires.
/// It can be null when utilization is 0 (no events to age out).
struct ExactSnapshot: Sendable, Equatable, Codable {
    struct Window: Sendable, Equatable, Codable {
        let utilization: Int
        let resetsAt: Date?
        /// Which model this window is scoped to, when Anthropic says so.
        ///
        /// The per-model weekly cap moved into `limits[].weekly_scoped`, and the
        /// payload names the model in `scope.model.display_name`. Measured
        /// 2026-08-22 on this account: the 100% cap was scoped to **Fable**
        /// while the UI called it "Weekly · Sonnet", because the value was
        /// stored in a field named `sevenDaySonnet` and the real name was
        /// discarded. `seven_day_sonnet` is `null` on current plans, so the old
        /// name was never right — it was left over from a shape Anthropic no
        /// longer sends.
        let scopedModel: String?

        init(utilization: Int, resetsAt: Date?, scopedModel: String? = nil) {
            self.utilization = utilization
            self.resetsAt = resetsAt
            self.scopedModel = scopedModel
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case scopedModel = "scoped_model"
        }
    }

    let fiveHour: Window
    let sevenDay: Window
    /// The per-model weekly window. Named for what it IS — a scoped cap — not for
    /// the model it happened to carry when this field was written.
    let sevenDayScoped: Window
    /// Kept so existing call sites keep compiling; new code should read
    /// `sevenDayScoped` and label it with `scopedModel`.
    var sevenDaySonnet: Window { sevenDayScoped }

    /// Local timestamp when this snapshot was fetched.
    let fetchedAt: Date

    init(fiveHour: Window, sevenDay: Window, sevenDayScoped: Window, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayScoped = sevenDayScoped
        self.fetchedAt = fetchedAt
    }

    /// Compatibility spelling for call sites written when the scoped window was
    /// assumed to be Sonnet. Kept so the rename does not churn every test.
    init(fiveHour: Window, sevenDay: Window, sevenDaySonnet: Window, fetchedAt: Date) {
        self.init(fiveHour: fiveHour, sevenDay: sevenDay,
                  sevenDayScoped: sevenDaySonnet, fetchedAt: fetchedAt)
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayScoped = "seven_day_scoped"
        case fetchedAt
    }

    /// Parse the raw JSON response from claude.ai's /usage endpoint.
    /// `fetchedAt` is set to the current Date; the endpoint doesn't echo it.
    static func decode(from json: Data, fetchedAt: Date = Date()) throws -> ExactSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractionalSeconds
        // The wire format omits fetchedAt — patch it in via a wrapper struct.
        let wire = try decoder.decode(Wire.self, from: json)
        return ExactSnapshot(
            fiveHour: wire.fiveHour,
            sevenDay: wire.sevenDay,
            // claude.ai now returns "seven_day_sonnet": null (the per-model window
            // was removed). Default to a zero window so the snapshot still decodes
            // — five_hour + seven_day are the binding numbers that matter.
            sevenDayScoped: wire.sevenDayScoped ?? Window(utilization: 0, resetsAt: nil),
            fetchedAt: fetchedAt
        )
    }

    private struct Wire: Decodable {
        let fiveHour: Window
        let sevenDay: Window
        /// The per-model weekly window, optional in this mirrored shape.
        let sevenDayScoped: Window?
        var sevenDaySonnet: Window? { sevenDayScoped }

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayScoped = "seven_day_scoped"
        }
    }

    /// True when this snapshot is still useful for display (newer than 10 min).
    func isFresh(now: Date = Date(), tolerance: TimeInterval = 10 * 60) -> Bool {
        now.timeIntervalSince(fetchedAt) < tolerance
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    /// claude.ai uses ISO-8601 with fractional seconds and timezone offset:
    /// "2026-04-28T19:00:00.742770+00:00". The default ISO8601 strategy
    /// rejects fractional seconds, so we install a custom formatter chain.
    static let iso8601withFractionalSeconds: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = primary.date(from: str) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        if let date = fallback.date(from: str) { return date }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unrecognized ISO-8601 timestamp: \(str)"
        )
    }
}
