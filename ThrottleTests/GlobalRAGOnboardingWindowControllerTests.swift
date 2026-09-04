import AppKit
@testable import Throttle
import XCTest

@MainActor
final class GlobalRAGOnboardingWindowControllerTests: XCTestCase {
    func testSetupUsesMovableResizableMacWindow() {
        let window = GlobalRAGOnboardingWindowController.makeWindow(
            contentViewController: NSViewController()
        )

        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.title, "Throttle — Global Portfolio Setup")
        XCTAssertGreaterThanOrEqual(window.minSize.width, 780)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 590)
    }

    func testRetainedPolicyDoesNotReleaseWindowDuringCloseCallback() {
        final class Delegate: NSObject, NSWindowDelegate {
            var closeCount = 0

            func windowWillClose(_ notification: Notification) {
                closeCount += 1
            }
        }
        let delegate = Delegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        RetainedWindowPolicy.configure(window, delegate: delegate)
        for _ in 0 ..< 100 {
            delegate.windowWillClose(
                Notification(name: NSWindow.willCloseNotification, object: window)
            )
        }

        XCTAssertEqual(delegate.closeCount, 100)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.delegate === delegate)
    }
}
