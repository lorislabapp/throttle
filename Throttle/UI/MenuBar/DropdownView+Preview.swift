import SwiftUI
import GRDB

#if DEBUG

// MARK: - Demo Preview for Screenshots & Video

/// SwiftUI previews with demo data for generating perfect marketing assets.
/// Use Xcode Canvas to render, then screenshot each state.
///
/// Usage:
/// 1. Open this file in Xcode
/// 2. Editor → Canvas → Show Canvas
/// 3. Select preview variant
/// 4. Cmd+Shift+4 to screenshot
/// 5. Export as PNG for Product Hunt / Twitter / landing page

struct DropdownView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // PREVIEW 1: Main meter view with €207 saved + all badges
            DropdownView()
                .environment(demoStateHighSavings)
                .previewDisplayName("Hero (€207 saved)")
                .frame(width: 340, height: 650)

            // PREVIEW 2: Medium savings (€45) - more realistic
            DropdownView()
                .environment(demoStateMediumSavings)
                .previewDisplayName("Medium (€45 saved)")
                .frame(width: 340, height: 600)

            // PREVIEW 3: Early user (€5) - shows progression potential
            DropdownView()
                .environment(demoStateEarlySavings)
                .previewDisplayName("Early User (€5 saved)")
                .frame(width: 340, height: 550)

            // PREVIEW 4: Pro upsell banner visible (Free tier)
            DropdownView()
                .environment(demoStateFreeUser)
                .previewDisplayName("Free Tier (Upsell)")
                .frame(width: 340, height: 600)
        }
    }

    // MARK: - Demo States

    /// High savings demo (€207) - shows max value prop
    /// Perfect for: Product Hunt hero image, Twitter thread screenshot
    private static var demoStateHighSavings: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.firstRunDone = true
        state.isPro = true

        // Session 6%, Weekly 80%, Sonnet 99% (visual contrast)
        state.snapshot = UsageSnapshot(
            session5h: UsageSnapshot.Window(
                kind: .session5h,
                usedTokens: 1_200_000,
                capTokens: 20_000_000,
                resetInSeconds: Int64(3 * 3600 + 51 * 60)
            ),
            weeklyAll: UsageSnapshot.Window(
                kind: .weeklyAll,
                usedTokens: 640_000_000,
                capTokens: 800_000_000,
                resetInSeconds: Int64(1 * 86400 + 7 * 3600)
            ),
            weeklySonnet: UsageSnapshot.Window(
                kind: .weeklySonnet,
                usedTokens: 792_000_000,
                capTokens: 800_000_000,
                resetInSeconds: Int64(1 * 86400 + 7 * 3600)
            ),
            computedAt: Date(),
            hasAnyData: true
        )

        // 45M tokens this week + 30M lifetime = 75M total = €207
        state.savedTokensThisWeek = 45_000_000
        state.savedTokensByDay = [2_000_000, 4_000_000, 6_000_000, 8_000_000, 10_000_000, 12_000_000, 8_000_000]

        // Unlock ALL milestones for max visual impact
        UserDefaults.standard.set(30_000_000, forKey: "throttle.milestone.lifetimeTokens")
        UserDefaults.standard.set(45_000_000, forKey: "throttle.milestone.lastWeeklySnapshot")
        UserDefaults.standard.set(["day_pro", "week_pro", "month_pro", "month_max5", "month_max20"],
                                  forKey: "throttle.milestone.fired")

        return state
    }

    /// Medium savings (€45) - more realistic for average user
    /// Perfect for: Reddit posts, landing page "after 2 weeks" scenario
    private static var demoStateMediumSavings: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.firstRunDone = true
        state.isPro = true

        state.snapshot = UsageSnapshot(
            session5h: UsageSnapshot.Window(
                kind: .session5h,
                usedTokens: 3_200_000,
                capTokens: 8_000_000,
                resetInSeconds: Int64(2 * 3600 + 15 * 60)
            ),
            weeklyAll: UsageSnapshot.Window(
                kind: .weeklyAll,
                usedTokens: 120_000_000,
                capTokens: 200_000_000,
                resetInSeconds: Int64(3 * 86400 + 4 * 3600)
            ),
            weeklySonnet: UsageSnapshot.Window(
                kind: .weeklySonnet,
                usedTokens: 95_000_000,
                capTokens: 200_000_000,
                resetInSeconds: Int64(3 * 86400 + 4 * 3600)
            ),
            computedAt: Date(),
            hasAnyData: true
        )

        // 12M tokens this week + 4M lifetime = 16M total = €44.16
        state.savedTokensThisWeek = 12_000_000
        state.savedTokensByDay = [500_000, 800_000, 1_200_000, 2_000_000, 2_500_000, 3_000_000, 2_000_000]

        UserDefaults.standard.set(4_000_000, forKey: "throttle.milestone.lifetimeTokens")
        UserDefaults.standard.set(["day_pro", "week_pro", "month_pro"], forKey: "throttle.milestone.fired")

        return state
    }

    /// Early savings (€5) - shows new user experience
    /// Perfect for: "after first few days" testimonial screenshots
    private static var demoStateEarlySavings: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.firstRunDone = true
        state.isPro = true

        state.snapshot = UsageSnapshot(
            session5h: UsageSnapshot.Window(
                kind: .session5h,
                usedTokens: 800_000,
                capTokens: 4_000_000,
                resetInSeconds: Int64(4 * 3600 + 30 * 60)
            ),
            weeklyAll: UsageSnapshot.Window(
                kind: .weeklyAll,
                usedTokens: 15_000_000,
                capTokens: 60_000_000,
                resetInSeconds: Int64(5 * 86400 + 2 * 3600)
            ),
            weeklySonnet: UsageSnapshot.Window(
                kind: .weeklySonnet,
                usedTokens: 12_000_000,
                capTokens: 60_000_000,
                resetInSeconds: Int64(5 * 86400 + 2 * 3600)
            ),
            computedAt: Date(),
            hasAnyData: true
        )

        // 1.8M tokens = €4.97 (just crossed "1 week of Pro" milestone)
        state.savedTokensThisWeek = 1_800_000
        state.savedTokensByDay = [100_000, 150_000, 200_000, 300_000, 400_000, 450_000, 200_000]

        UserDefaults.standard.set(0, forKey: "throttle.milestone.lifetimeTokens")
        UserDefaults.standard.set(["day_pro"], forKey: "throttle.milestone.fired")

        return state
    }

    /// Free tier with Pro upsell banner
    /// Perfect for: Landing page free tier screenshot
    private static var demoStateFreeUser: AppState {
        let state = AppState(database: try! DatabaseQueue())
        state.claudeCodeDetected = true
        state.firstRunDone = true
        state.isPro = false  // Free tier

        state.snapshot = UsageSnapshot(
            session5h: UsageSnapshot.Window(
                kind: .session5h,
                usedTokens: 1_500_000,
                capTokens: 4_000_000,
                resetInSeconds: Int64(3 * 3600 + 20 * 60)
            ),
            weeklyAll: UsageSnapshot.Window(
                kind: .weeklyAll,
                usedTokens: 25_000_000,
                capTokens: 60_000_000,
                resetInSeconds: Int64(4 * 86400 + 6 * 3600)
            ),
            weeklySonnet: UsageSnapshot.Window(
                kind: .weeklySonnet,
                usedTokens: 18_000_000,
                capTokens: 60_000_000,
                resetInSeconds: Int64(4 * 86400 + 6 * 3600)
            ),
            computedAt: Date(),
            hasAnyData: true
        )

        // No savings tracking in free tier (banner shows potential)
        state.savedTokensThisWeek = 0
        state.savedTokensByDay = [0, 0, 0, 0, 0, 0, 0]

        return state
    }
}

#endif
