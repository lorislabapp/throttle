import Foundation

// Tokopt hook mode: Claude Code invokes `Throttle --tokopt-hook` as a
// PostToolUse(Bash) hook. Handle it BEFORE any AppKit/SwiftUI initialization so
// it stays a fast, GUI-less CLI — read stdin, emit compressed output, exit.
// (Reuses the signed/notarized app binary; no separate helper target.)
if CommandLine.arguments.contains("--tokopt-hook") {
    TokoptHook.run()
    exit(0)
}

// MCP server mode: Claude Code launches `Throttle --mcp-server` and talks JSON-RPC
// over stdio to search the user's own past sessions (search_sessions tool).
if CommandLine.arguments.contains("--mcp-server") {
    ThrottleMCPServer.run()
    exit(0)
}

// Dev/test: reindex transcripts then run an FTS5 search (`Throttle --index-search "query"`).
if let i = CommandLine.arguments.firstIndex(of: "--index-search"), i + 1 < CommandLine.arguments.count {
    let added = TranscriptIndex.reindex()
    FileHandle.standardError.write(Data("indexed \(added) new messages\n".utf8))
    for h in TranscriptIndex.search(CommandLine.arguments[i + 1]).prefix(10) {
        print("[\(h.project) · \(h.role)] \(h.snippet)")
    }
    exit(0)
}

ThrottleApp.main()
