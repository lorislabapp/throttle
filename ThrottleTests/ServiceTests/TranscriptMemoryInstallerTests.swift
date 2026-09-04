@testable import Throttle
import XCTest

/// Path-healing for the throttle-memory MCP entry — the fix that auto-repoints a
/// stale exec path (dev DerivedData build → /Applications, or a Sparkle move) so
/// the new MCP tools reach the user without re-toggling.
final class TranscriptMemoryInstallerTests: XCTestCase {
    func testGlobalRAGHookOwnershipIsFailClosed() {
        XCTAssertTrue(GlobalRAGSessionContextInstaller.isManagedHookContents(
            GlobalRAGSessionContextInstaller.scriptContents
        ))
        XCTAssertFalse(GlobalRAGSessionContextInstaller.isManagedHookContents("#!/bin/sh\necho unrelated\n"))
        XCTAssertTrue(GlobalRAGSessionContextInstaller.directive.contains("Do not call throttle_global_context on every session"))
        XCTAssertTrue(GlobalRAGSessionContextInstaller.directive.contains("limit 6"))
    }

    func testGlobalRAGSessionHookMergeAndRemovalPreserveSiblingHooks() {
        let sibling: [String: Any] = ["type": "command", "command": "/usr/bin/existing"]
        let original: [String: Any] = [
            "hooks": ["SessionStart": [["matcher": "compact", "hooks": [sibling]]]],
            "permissions": ["allow": ["Read"]]
        ]
        let installed = GlobalRAGSessionContextInstaller.settingsByInstalling(in: original)
        let groups = ((installed["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String) == GlobalRAGSessionContextInstaller.command }.count, 1)

        let idempotent = GlobalRAGSessionContextInstaller.settingsByInstalling(in: installed)
        XCTAssertTrue(NSDictionary(dictionary: installed).isEqual(to: idempotent))
        let removed = GlobalRAGSessionContextInstaller.settingsByRemoving(from: idempotent)
        XCTAssertTrue(NSDictionary(dictionary: original).isEqual(to: removed))
    }

    func testGlobalRAGCodexManagedInstructionIsIdempotentAndReversible() {
        let original = "# User instructions\nKeep evidence literal.\n"
        let installed = GlobalRAGSessionContextInstaller.codexInstructionsInstalling(in: original)
        XCTAssertTrue(installed.contains("throttle_global_context"))
        XCTAssertEqual(installed.components(separatedBy: GlobalRAGSessionContextInstaller.codexBegin).count - 1, 1)
        let updated = GlobalRAGSessionContextInstaller.codexInstructionsInstalling(in: installed)
        XCTAssertEqual(updated.components(separatedBy: GlobalRAGSessionContextInstaller.codexBegin).count - 1, 1)
        XCTAssertEqual(GlobalRAGSessionContextInstaller.codexInstructionsRemoving(from: updated), original)
    }

    func testGlobalRAGCodexUsesNonEmptyOverrideAccordingToDocumentedPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(
            GlobalRAGSessionContextInstaller.activeCodexInstructionsURL(home: root).lastPathComponent,
            "AGENTS.md"
        )
        try "Override".write(to: codex.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(
            GlobalRAGSessionContextInstaller.activeCodexInstructionsURL(home: root).lastPathComponent,
            "AGENTS.override.md"
        )
    }

    func testGlobalRAGSessionInstallerFullIsolatedLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claude = root.appendingPathComponent(".claude", isDirectory: true)
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let originalSettings = #"{"permissions":{"allow":["Read"]}}"#
        let originalCodex = "# Existing global rule\nKeep evidence literal.\n"
        try originalSettings.write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        try originalCodex.write(to: codex.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        GlobalRAGSessionContextInstaller.homeOverride = root
        defer {
            GlobalRAGSessionContextInstaller.homeOverride = nil
            try? FileManager.default.removeItem(at: root)
        }

        try GlobalRAGSessionContextInstaller.install()
        try GlobalRAGSessionContextInstaller.install()
        XCTAssertTrue(GlobalRAGSessionContextInstaller.isInstalled())
        let settingsData = try Data(contentsOf: claude.appendingPathComponent("settings.json"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let groups = ((settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]]) ?? []
        XCTAssertEqual(groups.count, 1)
        let installedCodex = try String(contentsOf: codex.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(installedCodex.contains(originalCodex.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(installedCodex.components(separatedBy: GlobalRAGSessionContextInstaller.codexBegin).count - 1, 1)

        let hook = claude.appendingPathComponent("hooks/throttle-global-rag.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hook.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let hookData = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: hookData))
        XCTAssertTrue(String(decoding: hookData, as: UTF8.self).contains("throttle_global_context"))

        try GlobalRAGSessionContextInstaller.remove()
        XCTAssertFalse(GlobalRAGSessionContextInstaller.isInstalled())
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
        XCTAssertEqual(try String(contentsOf: codex.appendingPathComponent("AGENTS.md"), encoding: .utf8), originalCodex)
        let removedData = try Data(contentsOf: claude.appendingPathComponent("settings.json"))
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: removedData) as? [String: Any])
        XCTAssertNotNil(removed["permissions"])
        XCTAssertNil(removed["hooks"])
    }

    func testCodexManagedBlockInstallUpdateAndRemovePreservesSiblings() throws {
        let original = "model = \"gpt-test\"\n\n[mcp_servers.other]\ncommand = \"other\"\n"
        let installed = try TranscriptMemoryInstaller.codexConfigInstalling(
            in: original, execPath: "/Applications/Throttle.app/Contents/MacOS/Throttle"
        )
        XCTAssertTrue(installed.contains("[mcp_servers.throttle-memory]"))
        XCTAssertTrue(installed.contains("command = \"/Applications/Throttle.app/Contents/MacOS/Throttle\""))
        XCTAssertTrue(installed.contains("[mcp_servers.other]"))
        XCTAssertEqual(installed.components(separatedBy: "BEGIN THROTTLE MCP").count - 1, 1)

        let updated = try TranscriptMemoryInstaller.codexConfigInstalling(in: installed, execPath: "/New/Throttle")
        XCTAssertTrue(updated.contains("command = \"/New/Throttle\""))
        XCTAssertEqual(updated.components(separatedBy: "BEGIN THROTTLE MCP").count - 1, 1)
        XCTAssertEqual(TranscriptMemoryInstaller.codexConfigRemovingManagedBlock(from: updated), original)
    }

    func testCodexInstallerRefusesToOverwriteUnmanagedSameName() {
        let config = "[mcp_servers.throttle-memory]\ncommand = \"custom\"\n"
        XCTAssertThrowsError(try TranscriptMemoryInstaller.codexConfigInstalling(in: config, execPath: "/Throttle"))
    }

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
