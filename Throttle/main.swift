import Foundation

// Tokopt hook mode: Claude Code invokes `Throttle --tokopt-hook` as a
// PostToolUse(Bash) hook. Handle it BEFORE any AppKit/SwiftUI initialization so
// it stays a fast, GUI-less CLI — read stdin, emit compressed output, exit.
// (Reuses the signed/notarized app binary; no separate helper target.)
if CommandLine.arguments.contains("--tokopt-hook") {
    TokoptHook.run()
    exit(0)
}

// Pattern-A proxy CORE self-test (`Throttle --mcp-proxy-selftest <cmd> [args]`).
// MUST run before the --mcp-server check below, because the downstream <cmd> args
// legitimately contain "--mcp-server" (we proxy Throttle's own MCP as a test target).
if let i = CommandLine.arguments.firstIndex(of: "--mcp-proxy-selftest"), i + 1 < CommandLine.arguments.count {
    let child = MCPProxyChild(command: CommandLine.arguments[i + 1], args: Array(CommandLine.arguments[(i + 2)...]))
    let ok = child.startAndInitialize()
    let names = child.cachedTools.compactMap { $0["name"] as? String }
    FileHandle.standardError.write(Data("init=\(ok) tools=\(names)\n".utf8))
    let reok = ok && child.respawnAndReverify()
    FileHandle.standardError.write(Data("respawn+reverify(tools identical)=\(reok) err=\(child.lastError ?? "none")\n".utf8))
    child.shutdown()
    exit(ok && reok ? 0 : 1)
}

// Pattern-A proxy FRONT (`Throttle --mcp-proxy <PORT> <cmd> [args]`): a Streamable-
// HTTP MCP server Claude Code connects to, owning the downstream stdio server so it
// can respawn it without busting the prompt cache. Before --mcp-server (the <cmd>
// args may legitimately contain "--mcp-server").
if let i = CommandLine.arguments.firstIndex(of: "--mcp-proxy"),
   i + 2 < CommandLine.arguments.count, let port = UInt16(CommandLine.arguments[i + 1]) {
    MCPProxyServer.run(port: port, downstream: CommandLine.arguments[i + 2],
                       args: Array(CommandLine.arguments[(i + 3)...]))
}

// MCP server mode: Claude Code launches `Throttle --mcp-server` and talks JSON-RPC
// over stdio to search the user's own past sessions (search_sessions tool).
if CommandLine.arguments.contains("--mcp-server") {
    ThrottleMCPServer.run()
    exit(0)
}

// MCP supervisor mode (opt-in, Pattern-B): wrap ONE MCP server's command so it
// auto-respawns + drains stderr. The user sets a server's command to
// `Throttle --mcp-wrap <real-cmd> [args]` by hand — Throttle never rewrites config.
if let i = CommandLine.arguments.firstIndex(of: "--mcp-wrap"), i + 1 < CommandLine.arguments.count {
    MCPWrapper.run(Array(CommandLine.arguments[(i + 1)...]))
}

// Build/update the semantic corpus for a repo (`Throttle --index-repo <path>`):
// crawl text files, embed chunks on-device, persist incrementally. Heavy — runs
// as a one-shot CLI, never inside an MCP tool call.
if let i = CommandLine.arguments.firstIndex(of: "--index-repo"), i + 1 < CommandLine.arguments.count {
    let root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).standardizedFileURL
    var index = SemanticCorpusStore.loadIndex(repo: root.path)
    var manifest = SemanticCorpusStore.loadManifest(repo: root.path)
    let stats = RepoIndexer.indexDirectory(root, into: &index, manifest: &manifest)
    do {
        try SemanticCorpusStore.save(repo: root.path, index: index, manifest: manifest)
        FileHandle.standardError.write(Data("indexed \(stats.indexed) files (\(stats.chunks) chunks), \(stats.unchanged) unchanged, \(stats.removed) removed → \(index.chunkCount) chunks total\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("index-repo failed: \(error)\n".utf8)); exit(1)
    }
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
