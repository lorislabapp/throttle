#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity payload for the iOS lock screen + Dynamic Island: the Mac's
/// live Claude-usage binding number and a countdown to the window reset.
///
/// ActivityKit is iOS-only, so the whole type is behind `canImport(ActivityKit)`
/// — ThrottleShared is also linked into the macOS app, which has no ActivityKit.
/// Defined here (not in the app or the widget) because BOTH the iOS app (which
/// starts/updates the activity) and the widget extension (which renders it) must
/// share the exact same attribute + state shape.
public struct ThrottleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var fiveHour: Int          // 0…100
        public var sevenDay: Int          // 0…100
        public var binding: Int           // whichever window is highest — the one about to bite
        public var bindingResetsAt: Date? // absolute reset moment of the binding window
        public init(fiveHour: Int, sevenDay: Int, binding: Int, bindingResetsAt: Date?) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.binding = binding
            self.bindingResetsAt = bindingResetsAt
        }
    }

    /// The Mac this activity mirrors — shown so a user with more than one Mac
    /// knows whose usage the Dynamic Island is reporting.
    public var deviceName: String
    public init(deviceName: String) { self.deviceName = deviceName }
}
#endif
