import AppKit
import SwiftUI

/// A standalone window survives dismissal of the menu-bar popover. An open
/// preview is never replaced by a second request, especially during export.
@MainActor
final class DiagnosticsPreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = DiagnosticsPreviewWindowController()
    private var window: NSWindow?
    private var exportInProgress = false

    override private init() {}

    func show(report: DiagnosticReport,
              onExport: @escaping @MainActor (DiagnosticReport) async -> URL?) {
        if let window, window.isVisible || exportInProgress {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let preview = DiagnosticsPreviewView(report: report,
            onClose: { [weak self] in self?.window?.performClose(nil) },
            onExportState: { [weak self] in self?.exportInProgress = $0 },
            onExport: onExport)
        let target = window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        target.title = String(localized: "Preview diagnostics")
        target.contentViewController = NSHostingController(rootView: preview)
        target.minSize = NSSize(width: 520, height: 440)
        RetainedWindowPolicy.configure(target, delegate: self)
        if window == nil { target.center() }
        window = target
        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !exportInProgress }
}
