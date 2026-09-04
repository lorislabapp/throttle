import AppKit

/// Standalone Throttle windows are owned by singleton controllers and reused.
/// AppKit calls `windowWillClose` before it has finished closing the window, so
/// releasing the active NSWindow/SwiftUI graph from that callback is unsafe.
@MainActor
enum RetainedWindowPolicy {
    static func configure(_ window: NSWindow, delegate: NSWindowDelegate) {
        window.isReleasedWhenClosed = false
        window.delegate = delegate
    }
}
