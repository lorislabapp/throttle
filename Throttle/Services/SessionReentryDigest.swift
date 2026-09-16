import Foundation

/// What one session looked like at the moment attention left it and came back.
/// Deliberately a plain value: the digest is the part worth testing, and it
/// should not need a running cockpit to exist.
struct SessionReentrySnapshot: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let isLive: Bool
    let isHibernated: Bool
    /// The agent printed a question and appears to be waiting on an answer.
    let needsInput: Bool
    let latestQuestion: String?
    let questionAskedAt: Date?
    /// A stop that could not be confirmed, or any refusal the session recorded.
    let stopIssue: String?
    let rateLimitedUntil: Date?
    /// A heuristic, not a fact: the same tool cycling with nothing written.
    let repeatedTool: String?
    let repeats: Int
    let lastActivityAt: Date
    let spentEUR: Double?
}

/// The reading a person needs when they come back, not the one they need while
/// watching. Rebuilding situation awareness is the expensive part of returning
/// — measured at roughly a third of capacity even in systems designed to be
/// watched only by exception — so this answers "what happened while I was
/// away, and what actually wants me" instead of restating live state.
///
/// The tiers follow alarm-design practice rather than product instinct: only
/// something a person must resolve is an alarm. Progress, spend and heuristics
/// are status. A heuristic that is right less often than it is wrong is worse
/// than no signal at all, so a loop suspicion is never promoted to the top
/// tier — it is offered as something to look at, with its own evidence.
struct SessionReentryDigest: Sendable, Equatable {
    enum Tier: Int, Sendable, Comparable, CaseIterable {
        /// A person is the blocker. Nothing moves until they act.
        case waitingOnYou
        /// Something changed and is worth reading, but nothing is stuck.
        case moved
        /// Nothing happened while you were away.
        case quiet

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Item: Sendable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let tier: Tier
        /// One sentence: what happened, in the words a person would use.
        let headline: String
        /// Why it is in this tier, when that is a judgement rather than a fact.
        let note: String?
        let since: Date
    }

    let awaySince: Date
    let now: Date
    let items: [Item]
    /// Money the visible sessions burned during the absence, when known.
    let spentWhileAwayEUR: Double?

    var awayDuration: TimeInterval { max(0, now.timeIntervalSince(awaySince)) }
    func items(in tier: Tier) -> [Item] { items.filter { $0.tier == tier } }
    var isWorthShowing: Bool { items.contains { $0.tier != .quiet } }

    /// One line for the top of the panel. It names the count that matters and
    /// nothing else: a headline that lists everything is a headline nobody reads.
    var headline: String {
        let waiting = items(in: .waitingOnYou).count
        let moved = items(in: .moved).count
        let away = Self.duration(awayDuration)
        if waiting > 0 {
            return String(localized: "\(waiting) session(s) waiting on you after \(away)")
        }
        if moved > 0 {
            return String(localized: "\(moved) session(s) moved on while you were away, \(away)")
        }
        return String(localized: "Nothing moved in \(away)")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "under a minute") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        let rest = String(format: "%02d", minutes % 60)
        return minutes % 60 == 0 ? String(localized: "\(hours)h") : String(localized: "\(hours)h\(rest)")
    }
}

enum SessionReentryService {
    /// Below this, a person did not really leave, and a "while you were away"
    /// panel would be noise on top of a glance.
    static let minimumAbsence: TimeInterval = 10 * 60
    /// A loop suspicion is a heuristic. It is reported once it has repeated
    /// enough to be worth a look, and never as something that must be resolved.
    static let loopMentionThreshold = 4

    static func digest(
        snapshots: [SessionReentrySnapshot],
        awaySince: Date,
        now: Date = Date()
    ) -> SessionReentryDigest? {
        guard now.timeIntervalSince(awaySince) >= minimumAbsence else { return nil }
        let items = snapshots.map { item($0, awaySince: awaySince, now: now) }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                if $0.since != $1.since { return $0.since < $1.since }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        let spend = snapshots.compactMap(\.spentEUR)
        return SessionReentryDigest(
            awaySince: awaySince, now: now, items: items,
            spentWhileAwayEUR: spend.isEmpty ? nil : spend.reduce(0, +)
        )
    }

    /// The tier rules, in the order a person would apply them. A question beats
    /// a refusal because a question has an answer; a refusal beats a limit
    /// because a limit lifts by itself.
    private static func item(
        _ snapshot: SessionReentrySnapshot, awaySince: Date, now: Date
    ) -> SessionReentryDigest.Item {
        func make(_ tier: SessionReentryDigest.Tier, _ headline: String,
                  note: String? = nil, since: Date) -> SessionReentryDigest.Item {
            SessionReentryDigest.Item(id: snapshot.id, name: snapshot.name, tier: tier,
                                      headline: headline, note: note, since: since)
        }

        if snapshot.needsInput, let question = snapshot.latestQuestion {
            let asked = snapshot.questionAskedAt ?? snapshot.lastActivityAt
            let waited = SessionReentryDigest.duration(now.timeIntervalSince(asked))
            return make(.waitingOnYou, String(localized: "Asked: \(Self.oneLine(question))"),
                        note: String(localized: "waiting \(waited)"), since: asked)
        }
        if let issue = snapshot.stopIssue {
            return make(.waitingOnYou, Self.oneLine(issue),
                        note: String(localized: "the session recorded this and stopped"),
                        since: snapshot.lastActivityAt)
        }
        // A limit that has already lifted is history, not a thing to resolve.
        if let until = snapshot.rateLimitedUntil, until > now {
            let time = until.formatted(date: .omitted, time: .shortened)
            return make(.waitingOnYou, String(localized: "Rate limited until \(time)"),
                        note: String(localized: "nothing to do but wait or switch model"),
                        since: snapshot.lastActivityAt)
        }
        if let tool = snapshot.repeatedTool, snapshot.repeats >= loopMentionThreshold {
            return make(.moved, String(localized: "Repeated \(tool) \(snapshot.repeats) times with nothing written"),
                        note: String(localized: "a guess worth checking, not a verdict"),
                        since: snapshot.lastActivityAt)
        }
        if snapshot.lastActivityAt > awaySince {
            let ago = SessionReentryDigest.duration(now.timeIntervalSince(snapshot.lastActivityAt))
            let headline = snapshot.isLive
                ? String(localized: "Still working, last spoke \(ago) ago")
                : String(localized: "Worked, last spoke \(ago) ago")
            return make(.moved, headline, since: snapshot.lastActivityAt)
        }
        return make(.quiet, snapshot.isHibernated
                        ? String(localized: "Hibernated") : String(localized: "Silent the whole time"),
                    since: snapshot.lastActivityAt)
    }

    /// Questions and refusals arrive as terminal output. One line, bounded, and
    /// never re-wrapped into something the agent did not say.
    static func oneLine(_ text: String, limit: Int = 140) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
