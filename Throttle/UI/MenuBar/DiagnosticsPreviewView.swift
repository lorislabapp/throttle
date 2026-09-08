import AppKit
import SwiftUI

struct DiagnosticsPreviewView: View {
    let report: DiagnosticReport
    let onClose: () -> Void
    let onExportState: (Bool) -> Void
    let onExport: @MainActor (DiagnosticReport) async -> URL?
    @State private var exporting = false
    @State private var exportedURL: URL?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview diagnostics").font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Only the summary below will be saved. Nothing is uploaded or added to your AI conversation.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: report.text).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if exporting {
                ProgressView(String(localized: "Building…"))
            } else if failed {
                Text("Export failed. No data was uploaded. You can retry.").foregroundStyle(.red)
            } else if exportedURL != nil {
                Text("Summary saved to Desktop. Nothing was uploaded.")
            }
            HStack {
                Button(exportedURL == nil ? String(localized: "Cancel") : String(localized: "Close"),
                       action: onClose)
                    .keyboardShortcut(.cancelAction).disabled(exporting)
                Spacer()
                if let exportedURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
                } else {
                    Button("Save this summary to Desktop") {
                        exporting = true
                        failed = false
                        onExportState(true)
                        Task { @MainActor in
                            exportedURL = await onExport(report)
                            failed = exportedURL == nil
                            exporting = false
                            onExportState(false)
                        }
                    }
                    .disabled(exporting)
                }
            }
        }
        .padding(24)
    }
}
