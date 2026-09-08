import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Shared formatter for the settings and meter error messages.
func describeExactModeError(_ err: ExactModeError) -> String {
    switch err {
    case .notSignedIn:        return "Not signed in to claude.ai inside Throttle. Sign in and re-test."
    case .httpError(let code): return "HTTP \(code)"
    case .invalidResponse:    return "Bad response from claude.ai."
    case .session(let s):     return "Embedded session: \(s)"
    case .timeout:            return "Timed out."
    }
}
