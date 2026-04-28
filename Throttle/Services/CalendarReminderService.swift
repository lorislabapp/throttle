import EventKit
import Foundation
import OSLog

/// Writes a calendar event marking the next weekly-limit reset.
/// One-shot: user clicks a button, we add a single event for the
/// resets-at moment of `weeklyAll`. We don't auto-recreate weekly —
/// rolling-window resets shift constantly, so a single user-triggered
/// pin is more honest than a recurring rule that would drift.
@MainActor
enum CalendarReminderService {
    private static let logger = Logger(subsystem: "com.lorislab.throttle", category: "Calendar")

    enum Result {
        case added(eventId: String)
        case denied
        case noResetTime
        case error(String)
    }

    static func addNextWeeklyReset(in snapshot: UsageSnapshot, exact: ExactSnapshot?) async -> Result {
        let resetDate: Date? = {
            if let ex = exact, ex.isFresh(), let when = ex.sevenDay.resetsAt {
                return when
            }
            let secs = snapshot.weeklyAll.resetInSeconds
            guard secs > 0 else { return nil }
            return Date().addingTimeInterval(TimeInterval(secs))
        }()
        guard let resetDate else { return .noResetTime }

        let store = EKEventStore()
        // macOS 14+ uses requestFullAccessToEvents; older = requestAccess(to:).
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        guard granted else { return .denied }

        let event = EKEvent(eventStore: store)
        event.title = "Throttle: weekly Claude limit resets"
        event.notes = "Claude Code's rolling 7-day weekly cap renews around this time. Plan heavy work after this."
        event.startDate = resetDate
        event.endDate = resetDate.addingTimeInterval(15 * 60)
        event.calendar = store.defaultCalendarForNewEvents
        let alarm = EKAlarm(relativeOffset: -15 * 60)
        event.addAlarm(alarm)

        do {
            try store.save(event, span: .thisEvent, commit: true)
            logger.info("Added Calendar event \(event.eventIdentifier ?? "?", privacy: .public)")
            return .added(eventId: event.eventIdentifier ?? "")
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
