import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension InlineAssistantPane {
    var localWorkerServerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local worker server (optional)").font(.system(size: 12, weight: .medium))
            Text("Ollama URL on your own network — e.g. http://100.x.y.z:11434. Delegated tasks prefer it when it responds; otherwise the embedded model serves.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("http://host:11434", text: $localWorkerServerURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                SettingsButton(title: localWorkerProbing ? "Testing…" : "Test") { testLocalWorkerServer() }
            }
            localWorkerStatusBlock
        }
        .padding(.top, 6)
        .onAppear { if localWorkerStatus.state == .unconfigured && !localWorkerServerURL.isEmpty { testLocalWorkerServer() } }
    }

    /// Measured facts only: the dot reflects the last real probe, the numbers
    /// come from the server's own answers, and anything it did not tell us is
    /// simply absent rather than guessed.
    var localWorkerStatusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(localWorkerDotColor).frame(width: 7, height: 7)
                Text(localWorkerHeadline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(localWorkerStatus.state == .unreachable ? Color.orange : Color.primary)
                if let ms = localWorkerStatus.latencyMs, localWorkerStatus.state == .reachable {
                    Text("· \(ms) ms").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if let v = localWorkerStatus.version, localWorkerStatus.state == .reachable {
                    Text("· Ollama \(v)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            if localWorkerStatus.state == .reachable {
                if !localWorkerStatus.installedModels.isEmpty {
                    Picker("Model", selection: $localWorkerServerModel) {
                        ForEach(localWorkerStatus.installedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: localWorkerServerModel) { _, _ in
                        localWorkerStatus = LocalWorkerStatus(state: .unconfigured)
                        testLocalWorkerServer()
                    }
                    Text("Only models reported by this Ollama server are selectable. Throttle never pulls or runs a model just by selecting it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(LocalWorkerRouter.serverModel)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    if localWorkerStatus.modelInstalled == false {
                        Text("· not on the server — tasks fall back to the embedded model")
                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                    } else if localWorkerStatus.modelLoaded == true {
                        Text("· loaded" + (localWorkerStatus.residencyText.map { " · \($0)" } ?? ""))
                            .font(.system(size: 10.5))
                            .foregroundStyle(localWorkerStatus.mostlyOffGPU ? Color.orange : Color.secondary)
                        if localWorkerStatus.mostlyOffGPU {
                            Text("— most layers are outside VRAM (GPU memory taken elsewhere); expect CPU speed")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    } else if localWorkerStatus.modelLoaded == false {
                        Text("· idle (loads on first task)")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !localWorkerStatus.detail.isEmpty {
                Text(localWorkerStatus.detail)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if LocalWorkerRouter.serverTaskCount > 0 || LocalWorkerRouter.embeddedTaskCount > 0 {
                Text("\(LocalWorkerRouter.serverTaskCount) task(s) served here · \(LocalWorkerRouter.embeddedTaskCount) by the embedded model")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var localWorkerDotColor: Color {
        switch localWorkerStatus.state {
        case .reachable:    return localWorkerStatus.modelInstalled == false ? .orange : .green
        case .unreachable:  return .orange
        case .probing:      return .yellow
        case .unconfigured: return .secondary
        }
    }

    var localWorkerHeadline: String {
        switch localWorkerStatus.state {
        case .reachable:    return "Connected"
        case .unreachable:  return "Unreachable — embedded model serves"
        case .probing:      return "Probing…"
        case .unconfigured: return localWorkerServerURL.isEmpty ? "Not configured" : "Not checked yet"
        }
    }

    func testLocalWorkerServer() {
        guard !localWorkerProbing else { return }
        localWorkerProbing = true
        localWorkerStatus = LocalWorkerStatus(state: .probing)
        Task {
            let status = await LocalWorkerRouter.shared.detailedStatus()
            localWorkerStatus = status
            if let exact = LocalWorkerRouter.installedModelName(
                matching: localWorkerServerModel, in: status.installedModels
            ), exact != localWorkerServerModel {
                localWorkerServerModel = exact
            }
            localWorkerProbing = false
        }
    }

    func defaultProviderKind() -> AIProviderKind {
        if aiAvailability[.appleIntelligence] == true { return .appleIntelligence }
        if aiAvailability[.embeddedModel] == true { return .embeddedModel }
        if aiAvailability[.claudeAPIKey] == true { return .claudeAPIKey }
        return .appleIntelligence
    }

    func reloadAvailability() async {
        let map = await AIProviderRegistry.shared.availabilityMap()
        await MainActor.run {
            aiAvailability = map
            embeddedInstalled = EmbeddedModelRuntime.isInstalled
        }
    }

    func installEmbeddedModel() {
        guard !embeddedInstalling else { return }
        embeddedInstalling = true
        embeddedStatus = "Downloading model…"
        Task {
            do {
                try await EmbeddedModelRuntime.shared.install { fraction in
                    embeddedProgress = fraction
                    embeddedStatus = "Downloading model… \(Int(fraction * 100))%"
                }
                embeddedInstalled = true
                embeddedInstalling = false
                embeddedStatus = "Installed."
                await reloadAvailability()
            } catch {
                embeddedInstalling = false
                embeddedStatus = "Install failed: \(error.localizedDescription)"
            }
        }
    }

    func removeEmbeddedModel() {
        Task {
            do {
                try await EmbeddedModelRuntime.shared.removeInstalledModel()
                embeddedInstalled = false
                LocalDelegationService.isEnabled = false
                embeddedStatus = "Model removed."
                if AIProviderRegistry.shared.preferredKind == .embeddedModel {
                    AIProviderRegistry.shared.preferredKind = nil
                    aiSelection = nil
                }
                await reloadAvailability()
            } catch {
                embeddedStatus = "Removal failed: \(error.localizedDescription)"
            }
        }
    }

    func runImport() {
        Task {
            importing = true
            importStatus = ""
            do {
                let importer = CcusageImporter(database: appState.database)
                let days = try await importer.importFromCcusage()
                await MainActor.run {
                    appState.refresh()
                    importStatus = "✓ Imported \(days) days of usage data"
                    importing = false
                }
            } catch {
                await MainActor.run {
                    importStatus = "⚠️ Import failed: \(error.localizedDescription)"
                    importing = false
                }
            }
        }
    }
}
