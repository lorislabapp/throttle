import Foundation

// Tokopt hook mode: Claude Code invokes `Throttle --tokopt-hook` as a
// PostToolUse(Bash) hook. Handle it BEFORE any AppKit/SwiftUI initialization so
// it stays a fast, GUI-less CLI — read stdin, emit compressed output, exit.
// (Reuses the signed/notarized app binary; no separate helper target.)
if CommandLine.arguments.contains("--tokopt-hook") {
    TokoptHook.run()
    exit(0)
}

ThrottleApp.main()
