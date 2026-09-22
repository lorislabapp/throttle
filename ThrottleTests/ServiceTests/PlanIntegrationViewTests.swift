import AppKit
import SwiftUI
@testable import Throttle
import XCTest

/// Actual SwiftUI rendering/actions; journal fixtures never execute a project command.
@MainActor
final class PlanIntegrationViewTests: XCTestCase {
    func testUnknownIsVisibleAndCannotBeRetriedInEnglish() async throws {
        try await unknown(locale: "en", title: "Verification outcome pending")
    }

    func testUnknownIsVisibleAndCannotBeRetriedInFrench() async throws {
        try await unknown(locale: "fr", title: "Résultat de vérification en attente")
    }

    func testDiffFailureRetryAndEmptyStateInEnglish() async throws {
        try await diff(locale: "en", failure: "Diff unavailable", retry: "Retry diff",
                       empty: "No changes in this diff")
    }

    func testDiffFailureRetryAndEmptyStateInFrench() async throws {
        try await diff(locale: "fr", failure: "Diff indisponible", retry: "Réessayer le diff",
                       empty: "Aucune modification dans ce diff")
    }

    private func unknown(locale: String, title: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unknown-view-\(UUID())")
        let store = PlanStore(projectRoot: root)
        let task = PlanTask(id: "fixture", title: "Fixture", verify: "touch MUST_NOT_RUN")
        try store.bootstrap(Plan(projectId: "fixture", title: "Fixture", tasks: [task]))
        defer { try? FileManager.default.removeItem(at: root) }
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker:fixture", type: .claimed),
                         to: task.id)
        try store.append(TaskEvent(seq: 0, timestamp: Date(), author: "worker:fixture",
                                   type: .candidateComplete),
                         to: task.id)
        let lease = try TaskVerificationLifecycle.begin(taskID: task.id, store: store,
            request: .init(command: "touch MUST_NOT_RUN", stamp: "fixture+base",
                           author: "throttle:fixture", timeout: 1))
        let model = PlanModel()
        model.bind(to: root)
        defer { model.bind(to: nil) }
        model.integration.assessments[task.id] = Assessment(baseSHA: "base", taskSHA: "fixture", behindBy: 0,
            aheadBy: 1, isDirty: false, hasLooseWork: false, files: [], mergeability: .clean)
        let (window, host) = mount(IntegrationFixture(model: model, task: task), locale: locale)
        defer { window.close(); accessibility(false) }
        try await waitFor { self.text(host).contains(title) }
        XCTAssertTrue(text(host).contains(lease.id.uuidString))
        let buttons = nodes(host).filter { self.string($0, "accessibilityRole") == "AXButton" }
        let verify = try XCTUnwrap(buttons.first)
        XCTAssertFalse(bool(verify, "isAccessibilityEnabled"), "UNKNOWN must disable the actual action")
        let refusal = await model.integrate(taskID: task.id)
        XCTAssertNotNil(refusal)
        XCTAssertEqual(try store.state(for: task.id).pendingVerification, lease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("MUST_NOT_RUN").path))
        await capture(host, name: "unknown-\(locale)")
    }

    private func diff(locale: String, failure: String, retry: String, empty: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diff-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PlanModel()
        model.bind(to: root)
        defer { model.bind(to: nil) }
        model.integration.diffs["fixture"] = .failed("Fixture: reference unavailable")
        let (window, host) = mount(DiffFixture(model: model), locale: locale)
        defer { window.close(); accessibility(false) }
        try await waitFor { self.text(host).contains(failure) }
        XCTAssertFalse(text(host).contains(empty))
        let button = try XCTUnwrap(nodes(host).first { self.string($0, "accessibilityLabel") == retry })
        XCTAssertTrue(bool(button, "accessibilityPerformPress"))
        // Actual retry against a temporary directory without a task worktree must fail visibly.
        try await waitFor { model.integrationDiffState(for: "fixture") != .failed("Fixture: reference unavailable") }
        try await waitFor {
            if case .failed = model.integrationDiffState(for: "fixture") { return true }
            return false
        }
        try await waitFor { self.text(host).contains(failure) }
        if HostedViewReview.isEnabled {
            model.integration.diffs["fixture"] = .failed("Keyboard retry fixture: press Retry")
            try await waitFor { self.text(host).contains("Keyboard retry fixture") }
        }
        await capture(host, name: "diff-failed-\(locale)")
        model.integration.diffs["fixture"] = .loaded("+ recovered fixture")
        try await waitFor { self.text(host).contains("+ recovered fixture") }
        XCTAssertFalse(text(host).contains(failure))
        model.integration.diffs["fixture"] = .loaded("")
        try await waitFor { self.text(host).contains(empty) }
        XCTAssertFalse(text(host).contains("+ recovered fixture"))
        await capture(host, name: "diff-empty-\(locale)")
    }

    private struct IntegrationFixture: View {
        let model: PlanModel
        let task: PlanTask
        var body: some View { PlanTreeView(model: model).integration(task, model.state(task.id)) }
    }

    private struct DiffFixture: View {
        let model: PlanModel
        var body: some View { PlanTreeView(model: model).diffContent("fixture") }
    }

    private func mount(_ view: some View, locale: String) -> (NSWindow, NSView) {
        accessibility(true)
        let controller = NSHostingController(rootView: AnyView(VStack(alignment: .leading) { view }
            .padding(16).frame(width: 420, height: 420, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: locale))))
        // Keep the offscreen snapshot surface at the explicit fixture size.
        controller.sizingOptions = []
        let host = controller.view
        let style: NSWindow.StyleMask = HostedViewReview.isEnabled
            ? [.titled, .closable, .resizable] : [.borderless]
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 420),
                              styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 420, height: 420))
        window.orderBack(nil)
        HostedViewReview.prepare(window, title: "Integration")
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func accessibility(_ enabled: Bool) {
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                         with: NSNumber(value: enabled), with: "AXEnhancedUserInterface" as NSString)
    }

    private func nodes(_ node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 30 else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector)
            ? node.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
        return [node] + children.flatMap { nodes($0, depth: depth + 1) }
    }

    private func string(_ node: NSObject, _ name: String) -> String {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return "" }
        return node.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    private func text(_ node: NSObject) -> String {
        nodes(node).map { string($0, "accessibilityLabel") + " " + string($0, "accessibilityValue") }
            .joined(separator: " | ")
    }

    private func bool(_ node: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { XCTFail("Missing AX selector \(name)"); return false }
        typealias Method = @convention(c) (AnyObject, Selector) -> Bool
        let method = unsafeBitCast(node.method(for: selector), to: Method.self)
        return method(node, selector)
    }

    private func capture(_ host: NSView, name: String) async {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Snapshot unavailable: bounds=\(host.bounds), frame=\(host.frame)"); return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        await HostedViewReview.hold(host.window, scene: name)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Hosted view did not reach the expected state")
    }
}
