import SwiftUI

/// The cockpit's right sidebar. It renders exactly ONE segment at a time — the
/// same lifecycle that already applies when the inspector is hidden. That is
/// deliberate: the Audit segment's view model owns a polling task, and keeping
/// it mounted off-screen would run that loop for nothing. The refiner survives
/// the teardown because its state lives in `PromptRefinerModel`, not in a view.
struct CockpitSidebar: View {
    enum Tab: String, CaseIterable, Identifiable {
        case audit, refiner
        var id: String { rawValue }
        var label: String {
            switch self {
            case .audit:   return "Audit"
            case .refiner: return "Refiner"
            }
        }
        var help: String {
            switch self {
            case .audit:   return "Read-only usage metrics for this session and your windows"
            case .refiner: return "Turn a rough draft into a prompt worth sending"
            }
        }
    }

    @Binding var tab: Tab

    private let hair = Color.primary.opacity(0.10)

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tabOption in Text(tabOption.label).tag(tabOption) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(tab.help)
            .padding(.horizontal, 14).padding(.vertical, 12)

            Rectangle().fill(hair).frame(height: 1)

            switch tab {
            case .audit:   CockpitAuditInspector()
            case .refiner: PromptRefinerPane()
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
    }
}
