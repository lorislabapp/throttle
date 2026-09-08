import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct InlineGeneralPane: View {
    @Environment(AppState.self) var appState
    @State var loginItemsEnabled: Bool = LoginItemService.isEnabled
    @State var cockpitOnTop: Bool = CockpitWindowController.alwaysOnTop
    @State var hostCapabilities = CapabilityHostService.shared.enabled
    @State var notificationsOn: Bool = ThresholdNotifier.shared.isEnabled
    @State var calendarStatus: String = ""
    // Read the EFFECT, not a proxy for it. This switch used to report the flag
    // file it writes, so it showed "on" for months while the hooks that carry
    // the feature had never been installed — the install threw, `try?` ate it,
    // and the flag was written regardless. A switch that reports its own
    // intention rather than its result cannot be trusted to mean anything.
    @State var conciseClaudeCode: Bool = BrevityHookService.isInstalled()
    @State var conciseError: String?
    @AppStorage("throttleLowMemoryMode") var lowMemoryMode = false
    @AppStorage("throttleAutoPauseEnabled") var autoPauseEnabled = false
    @AppStorage("throttleOpusTokenCapEnabled") var opusCapEnabled = false
    @AppStorage("throttleOpusTokenCapK") var opusCapK = 200
    @AppStorage("throttleAutoTrimEnabled") var autoTrimEnabled = false
    @AppStorage("throttleAutoHibernateEnabled") var autoHibernateEnabled = true
    @AppStorage("throttleNodeHeapCapMB") var nodeHeapCapMB = 0
    @AppStorage("throttleMaxAgents") var maxAgents = 0
    @State var autopilotOn: Bool = AutopilotService.isEnabled
    @State var apMemory: Bool = AutopilotService.archiveStaleMemory
    @State var apSkills: Bool = AutopilotService.archiveDeadSkills
    @State var semanticAutoIndex: Bool = SemanticAutoIndexer.isEnabled
    @State var showingLedger = false
    @State var ledger: [AutopilotService.Entry] = []
    @State var autopilotBusy = false
    @State var activeStyle = OutputStyleManager.activeName()
    @State var dropImagesAsText = UserDefaults.standard.bool(forKey: DroppableTerminalView.ocrDefaultsKey)
    @State var tokoptOn = TokoptHookInstaller.isInstalled()
    @State var tokoptNote = ""
    @State var memoryOn = TranscriptMemoryInstaller.isInstalled()
    @State var memoryNote = ""
    @State var globalRAGNote = ""
    @State var traycerOn = UserDefaults.standard.bool(forKey: "throttleTraycerEnabled")
    @State var traycerNote = ""
    @State var webOn = UserDefaults.standard.bool(forKey: "throttleWebEnabled")
    @State var webNote = ""
    @State var peerFallbackHost = PeerTransport.shared.fallbackHost ?? ""
    @State var mirrorOn = UserDefaults.standard.bool(forKey: "throttleiCloudMirrorEnabled")
    @State var mirrorNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            autopilotGroup
            menuBarSettings
            generalSettings
            resourceSettings
            contextSettings
            connectionSettings
        }
        .sheet(isPresented: $showingLedger) { autopilotLedgerSheet }
        .onReceive(NotificationCenter.default.publisher(for: .outputStyleChanged)) { _ in
            activeStyle = OutputStyleManager.activeName()
        }
    }
}
