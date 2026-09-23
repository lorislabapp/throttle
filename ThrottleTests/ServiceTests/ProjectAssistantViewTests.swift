import AppKit
import GRDB
import SwiftUI
@testable import Throttle
import XCTest

/// The real Assistant view in the isolated XCTest host. The only substituted
/// boundaries are provider/context: no model, registry, defaults or file input.
@MainActor
final class ProjectAssistantViewTests: XCTestCase {
    func testEmptyStateMatchesSelectedLanguage() async throws {
        let fixture = try mount(ControlledAssistantProvider())
        defer { fixture.window.close(); enhancedAccessibility(false) }
        let french = Locale.current.language.languageCode?.identifier == "fr"
        let expected = french
            ? ["Audite ma configuration.", "Trouve les permissions dangereuses",
               "Mon CLAUDE.md", "Pourquoi Opus domine"]
            : ["Audit my setup.", "Find unsafe permissions", "Is my CLAUDE.md", "Why does Opus dominate"]
        try await waitFor { expected.allSatisfy { self.text(in: fixture.host).contains($0) } }
        await attachAX(fixture.host, named: "Assistant empty state")
    }

    func testStopBeforeFirstDeltaRejectsLateResponse() async throws {
        let provider = ControlledAssistantProvider()
        let fixture = try mount(provider)
        let host = fixture.host
        defer { fixture.window.close(); enhancedAccessibility(false) }
        try await send("Before first delta", in: host)
        try await waitFor { await provider.requestCount == 1 }
        try press("project-assistant-stop", in: host)
        try await waitFor { await provider.cancelledRequests.contains(0) }
        await provider.yield("LATE-BEFORE-DELTA", request: 0)
        try await waitFor { self.element("project-assistant-send", in: host) != nil }
        XCTAssertFalse(text(in: host).contains("LATE-BEFORE-DELTA"))
        let stoppedNote = String(localized:
            "Response stopped. A remote provider may still be finishing its request.")
        XCTAssertTrue(text(in: host).contains(stoppedNote))
        await attachAX(host, named: "Stopped before first delta")
    }

    func testStopDuringStreamKeepsNextTurnIndependent() async throws {
        let provider = ControlledAssistantProvider()
        let fixture = try mount(provider)
        let host = fixture.host
        defer { fixture.window.close(); enhancedAccessibility(false) }
        try await send("First request", in: host)
        try await waitFor { await provider.requestCount == 1 }
        await provider.yield("FIRST-VISIBLE-CHUNK", request: 0)
        try await waitFor { self.text(in: host).contains("FIRST-VISIBLE-CHUNK") }
        try press("project-assistant-stop", in: host)
        try await waitFor { await provider.cancelledRequests.contains(0) }
        let stoppedNote = String(localized:
            "Response stopped. A remote provider may still be finishing its request.")
        try await waitFor { self.text(in: host).contains(stoppedNote) }
        try await send("Second request", in: host)
        try await waitFor { await provider.requestCount == 2 }
        await provider.yield("OLD-REQUEST-LATE-CHUNK", request: 0)
        await provider.yield("SECOND-REQUEST-CHUNK", request: 1)
        try await waitFor { self.text(in: host).contains("SECOND-REQUEST-CHUNK") }
        XCTAssertNotNil(element("project-assistant-stop", in: host), "old completion did not clear new work")
        XCTAssertFalse(text(in: host).contains("OLD-REQUEST-LATE-CHUNK"))
        await provider.finish(request: 1)
        try await waitFor { self.element("project-assistant-send", in: host) != nil }
        XCTAssertTrue(text(in: host).contains("FIRST-VISIBLE-CHUNK"), "stopped partial answer remains visible")
        await attachAX(host, named: "Stopped response and completed next turn")
    }

    func testProjectChangeCancelsAndClearsOldTranscript() async throws {
        let provider = ControlledAssistantProvider()
        let fixture = try mount(provider)
        let host = fixture.host
        defer { fixture.window.close(); enhancedAccessibility(false) }
        try await send("Question in project A", in: host)
        try await waitFor { await provider.requestCount == 1 }
        await provider.yield("PROJECT-A-RESPONSE", request: 0)
        try await waitFor { self.text(in: host).contains("PROJECT-A-RESPONSE") }
        // Change the input of the same SwiftUI view, not its identity or window.
        fixture.selection.project = Self.project("B")
        try await waitFor { await provider.cancelledRequests.contains(0) }
        try await waitFor { !self.text(in: host).contains("PROJECT-A-RESPONSE") }
        await provider.yield("LATE-PROJECT-A", request: 0)
        try await send("Question in project B", in: host)
        try await waitFor { await provider.requestCount == 2 }
        let contexts = await provider.projectNames
        XCTAssertEqual(contexts, ["Fixture A", "Fixture B"])
        let latestMessages = await provider.latestMessages
        XCTAssertFalse(latestMessages.contains { $0.content.contains("project A") })
        await provider.yield("PROJECT-B-RESPONSE", request: 1)
        await provider.finish(request: 1)
        try await waitFor { self.text(in: host).contains("PROJECT-B-RESPONSE") }
        XCTAssertFalse(text(in: host).contains("LATE-PROJECT-A"))
        await attachAX(host, named: "Project B after changing the selected project")
    }

    private func send(_ message: String, in host: NSView) async throws {
        try await waitFor {
            self.element("project-assistant-send", in: host) != nil
                && self.text(in: host).contains("Controlled fixture provider")
        }
        let editor = try XCTUnwrap(textView(in: host))
        editor.string = message
        editor.didChangeText() // The native TextEditor delegate updates the actual SwiftUI binding.
        host.window?.makeFirstResponder(editor)
        await Task.yield()
        try press("project-assistant-send", in: host)
    }

    private struct MountedFixture {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let selection: Selection
    }

    private func mount(_ provider: ControlledAssistantProvider) throws -> MountedFixture {
        enhancedAccessibility(true)
        let selection = Selection(project: Self.project("A"))
        let runtime = ProjectAssistantTab.RuntimeOverride(provider: provider) { project in
            ProjectChatContext(projectName: project.displayName, projectPath: nil,
                               claudeMd: nil, settingsJSON: nil, weeklyTokens: 0,
                               modelSplit: [], hookScripts: [:], mcpServers: [], costEUR: 0)
        }
        let view = FixtureView(selection: selection, runtime: runtime)
            .environment(AppState(database: try DatabaseQueue(), readsLicenseState: false))
            .environment(\.locale, Locale.current)
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 850, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        HostedViewReview.prepare(window, title: "Assistant")
        host.layoutSubtreeIfNeeded()
        return MountedFixture(window: window, host: host, selection: selection)
    }

    private static func project(_ suffix: String) -> ProjectInfo {
        ProjectInfo(encodedName: "assistant-fixture-\(suffix)", projectPath: nil,
                    displayName: "Fixture \(suffix)", lastActive: .distantPast, pathExists: false)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func enhancedAccessibility(_ enabled: Bool) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        XCTAssertTrue(NSApp.responds(to: selector))
        _ = NSApp.perform(selector, with: NSNumber(value: enabled), with: "AXEnhancedUserInterface" as NSString)
    }

    private func value(_ name: String, on element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func element(_ identifier: String, in node: Any, depth: Int = 0) -> NSObject? {
        guard depth < 35, let node = node as? NSObject else { return nil }
        if value("accessibilityIdentifier", on: node) as? String == identifier { return node }
        return (value("accessibilityChildren", on: node) as? [Any] ?? [])
            .lazy.compactMap { self.element(identifier, in: $0, depth: depth + 1) }.first
    }

    private func press(_ identifier: String, in host: NSView) throws {
        let target = try XCTUnwrap(element(identifier, in: host), "Missing AX control \(identifier)")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(target.responds(to: selector))
        guard target.responds(to: selector) else { return }
        // NSObject.perform assumes an object return. This public AX action returns BOOL.
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(target.method(for: selector), to: Press.self)
        XCTAssertTrue(action(target, selector), "AXPress refused \(identifier)")
    }

    private func text(in node: Any, depth: Int = 0) -> String {
        guard depth < 35, let node = node as? NSObject else { return "" }
        let own = [value("accessibilityLabel", on: node), value("accessibilityValue", on: node)]
            .compactMap { $0 as? String }
        let children = (value("accessibilityChildren", on: node) as? [Any] ?? [])
            .map { text(in: $0, depth: depth + 1) }
        return (own + children).joined(separator: " | ")
    }

    private func attachAX(_ host: NSView, named name: String) async {
        let attachment = XCTAttachment(string: text(in: host))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Rasterize this actual hosted view, not a separate mockup or reconstructed image.
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("The hosted Assistant could not allocate a snapshot")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("The hosted Assistant snapshot could not be encoded")
            return
        }
        let snapshot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        snapshot.name = name + " — hosted view"
        snapshot.lifetime = .keepAlways
        add(snapshot)
        await HostedViewReview.hold(host.window, scene: name)
    }

    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let reached = await condition()
        XCTAssertTrue(reached, "Hosted Assistant did not reach the expected observable state")
    }

    @Observable
    final class Selection {
        var project: ProjectInfo
        init(project: ProjectInfo) { self.project = project }
    }

    private struct FixtureView: View {
        @Bindable var selection: Selection
        let runtime: ProjectAssistantTab.RuntimeOverride
        var body: some View {
            ProjectAssistantTab(project: selection.project, runtimeOverride: runtime)
        }
    }
}

private actor ControlledAssistantProvider: AIProvider {
    nonisolated let displayName = "Controlled fixture provider"
    nonisolated let kind: AIProviderKind = .appleIntelligence
    var isAvailable: Bool { true }
    private var streams: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private(set) var requestCount = 0
    private(set) var cancelledRequests: Set<Int> = []
    private(set) var projectNames: [String] = []
    private(set) var latestMessages: [ChatMessage] = []

    func streamChat(messages: [ChatMessage], context: ProjectChatContext) async throws
        -> AsyncThrowingStream<String, Error> {
        let request = requestCount
        requestCount += 1
        projectNames.append(context.projectName)
        latestMessages = messages
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        streams[request] = pair.continuation
        pair.continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.recordCancellation(request) } }
        }
        return pair.stream
    }

    private func recordCancellation(_ request: Int) { cancelledRequests.insert(request) }
    func yield(_ text: String, request: Int) { streams[request]?.yield(text) }
    func finish(request: Int) { streams[request]?.finish() }
}
