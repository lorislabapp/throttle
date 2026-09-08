import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineAssistantPane: View {
    @Environment(AppState.self) var appState
    @AppStorage("cavemanModeEnabled") var cavemanModeEnabled = false
    @AppStorage(LocalDelegationService.taskCountKey) var localDelegationTaskCount = 0
    @AppStorage(LocalDelegationService.sourceCharactersKey) var localDelegationSourceCharacters = 0
    @AppStorage(LocalDelegationService.returnedCharactersKey) var localDelegationReturnedCharacters = 0
    @State var importStatus: String = ""
    @State var importing: Bool = false
    @State var aiAvailability: [AIProviderKind: Bool] = [:]
    @State var aiSelection: AIProviderKind? = AIProviderRegistry.shared.preferredKind
    @State var aiKeyDraft: String = ""
    @State var aiKeyStatus: String = ""
    @State var embeddedInstalled = EmbeddedModelRuntime.isInstalled
    @State var embeddedInstalling = false
    @State var embeddedProgress = 0.0
    @AppStorage(LocalWorkerRouter.endpointKey) var localWorkerServerURL = ""
    @AppStorage(LocalWorkerRouter.modelKey) var localWorkerServerModel = LocalWorkerRouter.defaultServerModel
    @State var localWorkerStatus = LocalWorkerStatus()
    @State var localWorkerProbing = false
    @State var embeddedStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeader(label: "AI Assistant", desc: "Powers the Project window's chat")
            SettingsRow(title: "AI routing", sub: "See session, local/frontier and fallback rules together.") {
                SettingsButton(title: "Open…", systemImage: "arrow.triangle.branch") {
                    AIRoutingWindowController.shared.show()
                }
            }
            SettingsHair()
            SettingsRow(title: "Provider", sub: "Who answers \u{201C}why am I burning tokens?\u{201D}") {
                Picker("", selection: Binding(
                    get: { aiSelection ?? defaultProviderKind() },
                    set: { newValue in aiSelection = newValue; AIProviderRegistry.shared.preferredKind = newValue }
                )) {
                    Text("Apple").tag(AIProviderKind.appleIntelligence)
                    Text("Local").tag(AIProviderKind.embeddedModel)
                    Text("Claude").tag(AIProviderKind.claudeWebSession)
                    Text("API").tag(AIProviderKind.claudeAPIKey)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if (aiSelection ?? defaultProviderKind()) == .claudeAPIKey {
                SettingsHair()
                apiKeyRow
            }
            SettingsHair()
            embeddedModelRow
            SettingsHair()
            SettingsRow(title: "Caveman mode", sub: "Terse, telegraphic replies from the project Assistant. Ug.") {
                Toggle("", isOn: $cavemanModeEnabled).labelsHidden().toggleStyle(.switch).tint(.accentColor)
            }
            SettingsHair()
            SettingsRow(title: "Import ccusage data",
                        sub: importStatus.isEmpty ? "Pull usage history from the ccusage CLI." : importStatus) {
                SettingsButton(title: importing ? "Importing…" : "Import") { runImport() }
            }
        }
        .onAppear { Task { await reloadAvailability() } }
    }

    var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField("sk-ant-…", text: $aiKeyDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12).monospaced())
                SettingsButton(title: "Save") {
                    if ClaudeAPIKeyStore.write(aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        aiKeyStatus = String(localized: "Key saved."); aiKeyDraft = ""
                        Task { await reloadAvailability() }
                    } else {
                        aiKeyStatus = String(localized: "Save failed — keychain access denied?")
                    }
                }
                if ClaudeAPIKeyStore.read() != nil {
                    SettingsButton(title: "Remove", role: .destructive) {
                        _ = ClaudeAPIKeyStore.delete(); aiKeyStatus = String(localized: "Key removed.")
                        Task { await reloadAvailability() }
                    }
                }
            }
            Text(aiKeyStatus.isEmpty ? "Stored in macOS Keychain. Billed by Anthropic on this key." : aiKeyStatus)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    var embeddedModelRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !embeddedInstalled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Qwen 3 1.7B · embedded").font(.system(size: 12, weight: .medium))
                        Text(embeddedStatus.isEmpty
                             ? "968 MB one-time download. Runs inside Throttle; no Ollama or cloud fallback."
                             : embeddedStatus)
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        ModelCardLink(title: "Model card · Apache 2.0", url: EmbeddedModelRuntime.modelURL)
                            .font(.system(size: 10))
                    }
                    Spacer()
                    SettingsButton(title: embeddedInstalling
                                   ? "Installing \(Int(embeddedProgress * 100))%"
                                   : "Install") {
                        installEmbeddedModel()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                        Text(EmbeddedModelRuntime.displayName).font(.system(size: 12, weight: .medium))
                        Text("Installed in Throttle. Project context stays on this Mac; no daemon or cloud fallback.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                        ModelCardLink(title: "Model card · Apache 2.0", url: EmbeddedModelRuntime.modelURL)
                            .font(.system(size: 10))
                        }
                        Spacer()
                        SettingsButton(title: "Remove", role: .destructive) {
                            removeEmbeddedModel()
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { LocalDelegationService.isEnabled },
                        set: { LocalDelegationService.isEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delegate safe subtasks to Qwen").font(.system(size: 12, weight: .medium))
                            Text("Claude/Codex may offload summaries, extraction, classification and drafts. Exact quotes are checked; risky or weak results escalate back automatically.")
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch).tint(.accentColor)
                    if localDelegationTaskCount > 0 {
                        Text("\(localDelegationTaskCount) local tasks · \(max(0, localDelegationSourceCharacters - localDelegationReturnedCharacters)) source characters kept out of planner context.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            localWorkerServerRow
            localModelCatalog
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    var localModelCatalog: some View {
        DisclosureGroup("Recommended local models") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Catalog only: links open model cards. Throttle downloads only the supported embedded model when you press Install; selecting an Ollama model never pulls or starts it.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(LocalModelRecommendation.catalog) { item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name).font(.system(size: 11, weight: .medium))
                                Text(item.runtime.rawValue.uppercased())
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.fit).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Text(item.note).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        ModelCardLink(title: "Model card", url: item.modelURL).font(.system(size: 10))
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                }
                Text("Local provider routing: selected Ollama model → embedded MLX fallback only. It never falls back to Claude, Codex or another cloud provider.")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 7)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.top, 6)
    }

    /// Optional self-hosted Ollama endpoint for delegated tasks (e.g. a Proxmox
    /// LXC on the tailnet). When set and healthy it serves instead of the
    /// embedded model; any failure falls back to the embedded model silently.
}
