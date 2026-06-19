import Foundation
import IOKit.pwr_mgt
import OSLog

/// "Caffeine" mode — holds an IOPMAssertion so the Mac doesn't idle-sleep while a
/// claude session is working, so a long task isn't interrupted mid-run (which
/// would waste the tokens already spent). This is IDLE-sleep prevention with the
/// lid OPEN — it deliberately does NOT try to run lid-closed (clamshell): the
/// public power APIs can't prevent firmware lid-close sleep, and forcing it
/// (`pmset disablesleep`) needs admin + cooks the machine, especially on a
/// RAM-saturated Mac. Released automatically on disable / app quit.
@MainActor
@Observable
final class CaffeineService {
    static let shared = CaffeineService()

    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "Caffeine")
    private let defaultsKey = "cockpitCaffeineEnabled"
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    private(set) var active = false

    private init() {
        // Restore the user's choice on launch.
        if UserDefaults.standard.bool(forKey: defaultsKey) { setActive(true) }
    }

    var isEnabled: Bool { active }

    func toggle() { setActive(!active) }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        if on {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Throttle — keeping claude sessions awake" as CFString,
                &id)
            if result == kIOReturnSuccess {
                assertionID = id
                active = true
                UserDefaults.standard.set(true, forKey: defaultsKey)
                logger.info("Caffeine ON (idle-sleep prevented)")
            } else {
                logger.error("Caffeine assertion failed: \(result)")
            }
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
            active = false
            UserDefaults.standard.set(false, forKey: defaultsKey)
            logger.info("Caffeine OFF")
        }
    }
}
