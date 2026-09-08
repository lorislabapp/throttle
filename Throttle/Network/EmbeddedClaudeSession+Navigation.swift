import Foundation
import OSLog
@preconcurrency import WebKit

// MARK: - WKNavigationDelegate

extension EmbeddedClaudeSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in self.notifyNavigationFinished(error: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor in self.notifyNavigationFinished(error: error) }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error
    ) {
        Task { @MainActor in self.notifyNavigationFinished(error: error) }
    }

    /// Recover when the WebKit content process dies (sad-mac in the
    /// view, every subsequent `evaluateJavaScript` would silently fail).
    /// macOS 26.5 has a known RenderBox/Metal-shader path that can
    /// trigger this; the entitlements in `Throttle.entitlements`
    /// (allow-jit, allow-unsigned-executable-memory,
    /// disable-library-validation) mitigate but don't eliminate it.
    /// Re-load claude.ai/ to bring the view back to a usable state.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.logger.warning("WKWebView content process terminated — reloading claude.ai")
            // Drop any pending navigation continuations with a clear
            // error so callers don't wait forever.
            self.notifyNavigationFinished(error: EmbeddedSessionError.scriptError(
                "WebKit content process died — recovering"))
            if let endpoint = URL(string: "https://claude.ai/") {
                webView.load(URLRequest(url: endpoint))
            }
        }
    }
}
