import AppKit
import SwiftUI
@testable import Throttle
import XCTest

/// Exercise the real SwiftUI lifecycle and accessibility output in the isolated
/// XCTest host. No production model, CLI, preferences or terminal is touched.
@MainActor
final class CockpitSpendViewTests: XCTestCase {
    func testEmptyCardLoadsRefreshesAndCancelsWhenRemoved() async throws {
        var loads = 0
        var activeLoads = 0
        var maximumLoads = 0
        var rows: [ClaudeAgentInventory.Session] = []
        let card = OutsideAgentsCard(knownSessionIDs: [], loadSessions: {
            loads += 1
            activeLoads += 1
            maximumLoads = max(maximumLoads, activeLoads)
            try? await Task.sleep(for: .milliseconds(15))
            activeLoads -= 1
            return rows
        }, refreshInterval: .milliseconds(25), onOpen: { _ in XCTFail("must not open automatically") })
        let (window, host) = mount(card)
        defer { window.close(); enhancedAccessibility(false) }
        try await waitFor { loads > 0 }
        XCTAssertFalse(text(in: host).contains("Outside fixture"))
        rows = [session()]
        try await waitFor { self.text(in: host).contains("Outside fixture") }
        rows = []
        try await waitFor { !self.text(in: host).contains("Outside fixture") }
        XCTAssertEqual(maximumLoads, 1, "refreshes must never overlap")
        host.rootView = english(EmptyView())
        try await Task.sleep(for: .milliseconds(100))
        let stoppedAt = loads
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, stoppedAt, "leaving Today must stop polling")
    }

    func testCloudShowsUnmeasuredAndAlreadyOpenSessionIsExcluded() async throws {
        let cloud = session(kind: "cloud")
        let (window, host) = mount(OutsideAgentsCard(knownSessionIDs: [], loadSessions: { [cloud] },
                                                    onOpen: { _ in XCTFail("unexpected attach") }))
        defer { window.close(); enhancedAccessibility(false) }
        try await waitFor { self.text(in: host).contains("Outside fixture") }
        XCTAssertTrue(text(in: host).contains("Not measured"))
        XCTAssertFalse(text(in: host).contains("€"))
        host.rootView = english(OutsideAgentsCard(knownSessionIDs: ["session-id"], loadSessions: { [cloud] },
                                                  onOpen: { _ in XCTFail("unexpected attach") }))
        try await waitFor { !self.text(in: host).contains("Outside fixture") }
    }

    func testTaskCostDistinguishesUnknownFromObservedZero() {
        let (window, host) = mount(TaskSpendLabel(entry: nil))
        defer { window.close(); enhancedAccessibility(false) }
        XCTAssertTrue(text(in: host).contains("Not measured"))
        XCTAssertFalse(text(in: host).contains("€"))
        host.rootView = english(TaskSpendLabel(entry: .init(taskID: "T1", sessionIDs: ["a"], costEUR: 0)))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(text(in: host).contains("≈"))
        XCTAssertTrue(text(in: host).contains("€"))
        XCTAssertFalse(text(in: host).contains("Not measured"))
    }

    func testPlanKeepsUnknownCountsAndSubscriptionDisclosureVisible() {
        let (window, host) = mount(PlanSpendReadout(total: .init(costEUR: 0, measured: 0, unmeasured: 2)))
        defer { window.close(); enhancedAccessibility(false) }
        XCTAssertTrue(text(in: host).contains("Not measured"))
        XCTAssertFalse(text(in: host).contains("€"))
        XCTAssertTrue(text(in: host).contains("0 task(s) measured · 2 not measured"))
        host.rootView = english(PlanSpendReadout(total: .init(costEUR: 1.5, measured: 1, unmeasured: 2)))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(text(in: host).contains("≈"))
        XCTAssertTrue(text(in: host).contains("1 task(s) measured · 2 not measured"))
        XCTAssertTrue(text(in: host).contains("Not your subscription, and never added to it."))
    }

    private func session(kind: String = "background") -> ClaudeAgentInventory.Session {
        .init(id: "fixture", sessionID: "session-id", name: "Outside fixture", cwd: "/fixture",
              kind: kind, state: "blocked", startedAt: nil)
    }

    private func english(_ view: some View) -> AnyView {
        AnyView(view.environment(\.locale, Locale(identifier: "en_US")))
    }

    private func mount(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        enhancedAccessibility(true)
        let host = NSHostingView(rootView: english(view))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    // Enable AX only in this isolated test process; SwiftUI otherwise builds no tree.
    private func enhancedAccessibility(_ enabled: Bool) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        XCTAssertTrue(NSApp.responds(to: selector))
        _ = NSApp.perform(selector, with: NSNumber(value: enabled), with: "AXEnhancedUserInterface" as NSString)
    }

    private func text(in node: Any, depth: Int = 0) -> String {
        guard depth < 30, let element = node as? NSObject else { return "" }
        // SwiftUI AX nodes answer these public selectors without declaring
        // NSAccessibilityProtocol conformance. A protocol cast drops their text.
        func value(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        let own = [value("accessibilityLabel"), value("accessibilityValue")].compactMap { $0 as? String }
        let children = (value("accessibilityChildren") as? [Any] ?? []).map { text(in: $0, depth: depth + 1) }
        return (own + children).joined(separator: " | ")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "hosted view did not reach the expected state")
    }
}
