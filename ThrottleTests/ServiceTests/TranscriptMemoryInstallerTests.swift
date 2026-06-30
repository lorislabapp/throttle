import XCTest
@testable import Throttle

/// Path-healing for the throttle-memory MCP entry — the fix that auto-repoints a
/// stale exec path (dev DerivedData build → /Applications, or a Sparkle move) so
/// the new MCP tools reach the user without re-toggling.
final class TranscriptMemoryInstallerTests: XCTestCase {

    private let appPath = "/Applications/Throttle.app/Contents/MacOS/Throttle"
    private let oldPath = "/Users/x/Library/Developer/Xcode/DerivedData/Throttle-abc/Build/Products/Debug/Throttle.app/Contents/MacOS/Throttle"

    private func config(command: String) -> [String: Any] {
        ["mcpServers": ["throttle-memory": ["command": command, "args": ["--mcp-server"]]]]
    }

    func test_healing_repointsStalePath() {
        let healed = TranscriptMemoryInstaller.healing(config(command: oldPath), execPath: appPath)
        let cmd = ((healed?["mcpServers"] as? [String: Any])?["throttle-memory"] as? [String: Any])?["command"] as? String
        XCTAssertEqual(cmd, appPath)
    }

    func test_healing_nilWhenAlreadyCurrent() {
        XCTAssertNil(TranscriptMemoryInstaller.healing(config(command: appPath), execPath: appPath))
    }

    func test_healing_nilWhenNotInstalled() {
        XCTAssertNil(TranscriptMemoryInstaller.healing(["mcpServers": [:]], execPath: appPath))
        XCTAssertNil(TranscriptMemoryInstaller.healing([:], execPath: appPath))
    }

    func test_healing_preservesOtherServers_andArgs() {
        var c = config(command: oldPath)
        c["mcpServers"] = ["throttle-memory": ["command": oldPath, "args": ["--mcp-server"]],
                           "other": ["command": "/usr/bin/other"]]
        let healed = TranscriptMemoryInstaller.healing(c, execPath: appPath)
        let mcp = healed?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcp?["other"], "untouched servers preserved")
        let args = (mcp?["throttle-memory"] as? [String: Any])?["args"] as? [String]
        XCTAssertEqual(args, ["--mcp-server"])
    }

    func test_healing_addsMissingArgs() {
        let c: [String: Any] = ["mcpServers": ["throttle-memory": ["command": oldPath]]]
        let healed = TranscriptMemoryInstaller.healing(c, execPath: appPath)
        let args = ((healed?["mcpServers"] as? [String: Any])?["throttle-memory"] as? [String: Any])?["args"] as? [String]
        XCTAssertEqual(args, ["--mcp-server"])
    }
}
