@testable import Throttle
import XCTest

final class BrevityHookServiceTests: XCTestCase {
    func test_hookSettingsGenerateBothRequiredEvents() throws {
        let generated = BrevityHookService.settingsByInstallingHooks(in: [:])
        let hooks = try XCTUnwrap(generated["hooks"] as? [String: Any])

        let promptGroups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let promptCommands = try XCTUnwrap(promptGroups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(promptCommands.first?["type"] as? String, "command")
        XCTAssertEqual(promptCommands.first?["command"] as? String, BrevityHookService.command)

        let sessionGroups = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(sessionGroups.first?["matcher"] as? String, "compact")
        let sessionCommands = try XCTUnwrap(sessionGroups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(sessionCommands.first?["command"] as? String, BrevityHookService.command)
    }

    func test_hookSettingsPreserveExistingUserHooksAndAreIdempotent() throws {
        let original: [String: Any] = [
            "theme": "dark",
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "/usr/local/bin/user-hook"]]]
                ]
            ]
        ]

        let once = BrevityHookService.settingsByInstallingHooks(in: original)
        let twice = BrevityHookService.settingsByInstallingHooks(in: once)
        XCTAssertTrue(NSDictionary(dictionary: once).isEqual(to: twice))
        XCTAssertEqual(once["theme"] as? String, "dark")

        let hooks = try XCTUnwrap(once["hooks"] as? [String: Any])
        let groups = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        let userCommands = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(userCommands.first?["command"] as? String, "/usr/local/bin/user-hook")
    }

    func test_userPromptSubmitPayloadUsesAdditionalContext() throws {
        let object = try runGeneratedScript(eventName: "UserPromptSubmit")
        let output = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "UserPromptSubmit")
        XCTAssertEqual(output["additionalContext"] as? String, BrevityHookService.directive)
    }

    func test_sessionStartPayloadUsesAdditionalContext() throws {
        let object = try runGeneratedScript(eventName: "SessionStart")
        let output = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "SessionStart")
        XCTAssertEqual(output["additionalContext"] as? String, BrevityHookService.directive)
    }

    private func runGeneratedScript(eventName: String) throws -> [String: Any] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data().write(to: claude.appendingPathComponent("throttle-concise"))
        let script = home.appendingPathComponent("brevity.sh")
        try BrevityHookService.scriptContents.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"\#(eventName)"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

final class OutputStyleShadowingDetectorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func test_detectsLocalOutputStyleThatOverridesGlobalSettings() throws {
        let project = tempDirectory.appendingPathComponent("Project", isDirectory: true)
        let local = project.appendingPathComponent(".claude/settings.local.json")
        let global = tempDirectory.appendingPathComponent("settings.json")
        try writeJSON(["outputStyle": "Caveman"], to: local)
        try writeJSON(["outputStyle": "Throttle Concise"], to: global)

        let warning = try XCTUnwrap(
            OutputStyleShadowingDetector.detect(projectURL: project, globalSettingsURL: global)
        )
        XCTAssertEqual(warning.localStyle, "Caveman")
        XCTAssertEqual(warning.globalStyle, "Throttle Concise")
        XCTAssertEqual(warning.settingsPath, local.path)
    }

    func test_identicalLocalStyleStillWarnsBecauseProjectIsPinned() throws {
        let project = tempDirectory.appendingPathComponent("Project", isDirectory: true)
        let local = project.appendingPathComponent(".claude/settings.local.json")
        let global = tempDirectory.appendingPathComponent("settings.json")
        try writeJSON(["outputStyle": "Caveman"], to: local)
        try writeJSON(["outputStyle": "Caveman"], to: global)

        XCTAssertNotNil(
            OutputStyleShadowingDetector.detect(projectURL: project, globalSettingsURL: global)
        )
    }

    func test_missingOrMalformedLocalSettingsDoNotWarn() throws {
        let project = tempDirectory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertNil(OutputStyleShadowingDetector.detect(projectURL: project))

        let local = project.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: local)
        XCTAssertNil(OutputStyleShadowingDetector.detect(projectURL: project))
    }

    func test_emptyOrNonStringOutputStyleDoesNotWarn() {
        XCTAssertNil(OutputStyleShadowingDetector.outputStyle(in: Data(#"{"outputStyle":"  "}"#.utf8)))
        XCTAssertNil(OutputStyleShadowingDetector.outputStyle(in: Data(#"{"outputStyle":42}"#.utf8)))
        XCTAssertEqual(
            OutputStyleShadowingDetector.outputStyle(in: Data(#"{"outputStyle":"  Learning  "}"#.utf8)),
            "Learning"
        )
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }
}
