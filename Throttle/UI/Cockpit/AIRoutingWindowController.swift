import AppKit
import SwiftUI

/// One place for the route between coding runtimes and inference providers.
/// Kept out of Settings because users need this while deciding where work runs,
/// not while maintaining the app.
@MainActor
final class AIRoutingWindowController: NSObject {
    static let shared = AIRoutingWindowController()

    private var window: NSWindow?

    override private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: AIRoutingView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "AI Routing — Local & Frontier"
        win.minSize = NSSize(width: 600, height: 520)
        win.contentViewController = host
        win.center()
        RetainedWindowPolicy.configure(win, delegate: self)
        win.setFrameAutosaveName("ThrottleAIRoutingWindow")
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AIRoutingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {}
}

private struct AIRoutingView: View {
    @State private var cockpit = MultiCockpitModel.shared
    @State private var assistantProvider = AIProviderRegistry.shared.preferredKind ?? .embeddedModel
    @State private var availability: [AIProviderKind: Bool] = [:]
    @AppStorage(LocalDelegationService.enabledKey) private var delegationEnabled = false
    @AppStorage(LocalWorkerRouter.endpointKey) private var workerURL = ""
    @AppStorage(LocalWorkerRouter.modelKey) private var workerModel = LocalWorkerRouter.defaultServerModel
    @State private var workerStatus = LocalWorkerStatus()
    @State private var probingWorker = false

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                heading
                currentContext
                codingRoute
                assistantRoute
                localInference
                rateLimitPolicy
            }
            .padding(20)
        }
        .task {
            availability = await AIProviderRegistry.shared.availabilityMap()
            if !workerURL.isEmpty { await testWorker() }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Routing").font(.system(size: 22, weight: .bold))
            Text("Choose where new coding sessions run and which model answers Assistant work. Existing sessions never move silently.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentContext: some View {
        routingCard("CURRENT COCKPIT CONTEXT", symbol: "scope") {
            if let session = cockpit.active {
                routeFact("Project", session.projectName)
                routeFact("Path", session.cwd, monospaced: true)
                routeFact("Session", String((session.sessionId ?? session.id.uuidString).prefix(8)))
                routeFact("Runtime", session.runtime.label)
            } else {
                Text("No active Cockpit session.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var codingRoute: some View {
        routingCard("NEW CODING SESSIONS", symbol: "terminal") {
            Picker("Runtime", selection: $cockpit.routingMode) {
                ForEach(MissionRoutingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(cockpit.routingMode.detail)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Label("Local Qwen is not shown here: it has no provider-native terminal, tools or resumable coding-session contract.",
                  systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var assistantRoute: some View {
        routingCard("PROJECT ASSISTANT", symbol: "bubble.left.and.text.bubble.right") {
            Picker("Provider", selection: $assistantProvider) {
                ForEach(AIProviderKind.allCases, id: \.self) { provider in
                    Text(providerLabel(provider)).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: assistantProvider) { _, provider in
                AIProviderRegistry.shared.preferredKind = provider
            }
            Text(providerExplanation(assistantProvider))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if availability[assistantProvider] == false {
                Label("This provider is not ready on this Mac. Configure it before relying on it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var localInference: some View {
        routingCard("LOCAL INFERENCE", symbol: "cpu") {
            routeFact("Embedded", EmbeddedModelRuntime.isInstalled
                      ? "Qwen 3 1.7B · installed in Throttle"
                      : "Not installed")
            Toggle("Delegate safe summaries, extraction, classification and drafts",
                   isOn: $delegationEnabled)
                .toggleStyle(.switch).tint(.accentColor)

            Divider().padding(.vertical, 2)
            Text("Optional Ollama worker").font(.system(size: 12, weight: .semibold))
            Text("Leave this empty to use only the embedded model.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("http://host:11434", text: $workerURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button(probingWorker ? "Testing…" : "Test") {
                    Task { await testWorker() }
                }
                .disabled(probingWorker || workerURL.isEmpty)
            }
            workerTruth

            Button("Open advanced AI settings…") {
                if let url = URL(string: "throttle://settings/ai") {
                    NSWorkspace.openInBackground(url)
                }
            }
            .buttonStyle(.link).controlSize(.small)
        }
    }

    @ViewBuilder
    private var workerTruth: some View {
        switch workerStatus.state {
        case .unconfigured:
            Label("Not configured — embedded Qwen serves local work", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .probing:
            Label("Testing the worker…", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .unreachable:
            Label("Worker unreachable — embedded Qwen serves local work", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .reachable:
            VStack(alignment: .leading, spacing: 5) {
                Label("Connected\(workerStatus.latencyMs.map { " · \($0) ms" } ?? "")",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !workerStatus.installedModels.isEmpty {
                    Picker("Server model", selection: $workerModel) {
                        ForEach(workerStatus.installedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .onChange(of: workerModel) { _, _ in Task { await testWorker() } }
                }
                Text(workerStatus.modelLoaded == true
                     ? "\(workerModel) is loaded and preferred over embedded Qwen."
                     : "\(workerModel) loads on the first task; embedded Qwen is the fallback.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var rateLimitPolicy: some View {
        routingCard("RATE-LIMIT RECOVERY", symbol: "arrow.triangle.branch") {
            routeFact("Coding session", "Offer a reviewed handoff to Codex")
            routeFact("Local Qwen", "Still available for bounded work and Project Assistant chat")
            Text("Throttle does not pretend a local model can resume a Claude/Codex terminal session. A future local coding runtime needs its own tools, permissions, worktree and transcript contract.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func testWorker() async {
        probingWorker = true
        workerStatus = LocalWorkerStatus(state: .probing)
        let result = await LocalWorkerRouter.shared.detailedStatus()
        workerStatus = result
        if let exact = LocalWorkerRouter.installedModelName(
            matching: workerModel, in: result.installedModels
        ), exact != workerModel {
            workerModel = exact
        }
        probingWorker = false
    }

    private func providerLabel(_ provider: AIProviderKind) -> String {
        switch provider {
        case .appleIntelligence: return "Apple"
        case .embeddedModel: return "Local"
        case .claudeWebSession: return "Claude"
        case .claudeAPIKey: return "API"
        }
    }

    private func providerExplanation(_ provider: AIProviderKind) -> String {
        switch provider {
        case .appleIntelligence: return "On-device Apple Intelligence for Assistant chat."
        case .embeddedModel: return "Embedded Qwen or your optional Ollama worker. No cloud fallback."
        case .claudeWebSession: return "Frontier answers through your Claude subscription."
        case .claudeAPIKey: return "Frontier answers billed through your configured Anthropic API key."
        }
    }

    private func routeFact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func routingCard<Content: View>(_ title: String, symbol: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hair, lineWidth: 1))
    }
}
