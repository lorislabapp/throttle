import CryptoKit
import Foundation
@testable import ThrottleShared
import XCTest

final class EdgeRuntimeDeploymentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edge-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func run(_ script: String, in root: URL, syntaxOnly: Bool = false, path: String? = nil) throws -> Int32 {
        let file = root.appendingPathComponent("script-\(UUID()).sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = syntaxOnly ? ["-n", file.path] : [file.path]
        if let path { process.environment = ["PATH": path, "HOME": root.path] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testGeneratedManualAndStepScriptsParseWithoutExecutingDeployment() throws {
        let root = try directory()
        let target = EdgeAgentService.SSHTarget(host: "fixture.example.ts.net")
        let manual = EdgeAgentService.deployScript(
            target: target, token: "fixture", httpPort: 8787, agentSource: "// fixture")
        XCTAssertEqual(try run(manual, in: root, syntaxOnly: true), 0)
        for step in EdgeAgentService.deploySteps(token: "fixture", httpPort: 8787, agentSource: "// fixture") {
            XCTAssertEqual(try run(step.script, in: root, syntaxOnly: true), 0, step.label)
        }
    }

    func testIncorrectArchiveDigestCannotReplaceExistingPrivateRuntime() throws {
        let root = try directory(), binaries = root.appendingPathComponent("bin")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let existing = runtime.appendingPathComponent("node-v\(EdgeAgentService.nodeVersion)")
        try Data("existing runtime".utf8).write(to: existing)
        let commands = [
            "uname": "#!/bin/sh\nprintf 'x86_64\\n'\n",
            "curl": "#!/bin/sh\nwhile [ \"$1\" != '-o' ]; do shift; done\nprintf corrupt > \"$2\"\n",
            "sha256sum": "#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n"
        ]
        for (name, script) in commands {
            let file = binaries.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let script = EdgeAgentService.nodeInstallationScript
            .replacingOccurrences(of: "/opt/throttle-agent/runtime", with: runtime.path)
        XCTAssertNotEqual(try run(script, in: root, path: binaries.path + ":/usr/bin:/bin"), 0)
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing runtime".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.path), [existing.lastPathComponent])
    }

    func testIncorrectClaudeDigestCannotReplaceExistingPinnedCLI() throws {
        let root = try directory(), binaries = root.appendingPathComponent("bin")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let existing = runtime.appendingPathComponent("claude-\(EdgeAgentService.claudeCodeVersion)")
        try Data("existing cli".utf8).write(to: existing)
        let commands = [
            "uname": "#!/bin/sh\\nprintf 'x86_64\\n'\\n",
            "curl": "#!/bin/sh\\nwhile [ \"$1\" != '-o' ]; do shift; done\\nprintf corrupt > \"$2\"\\n",
            "sha256sum": "#!/bin/sh\\nexec /usr/bin/shasum -a 256 \"$@\"\\n"
        ]
        for (name, script) in commands {
            let file = binaries.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let script = EdgeAgentService.claudeInstallationScript
            .replacingOccurrences(of: "/opt/throttle-agent/runtime", with: runtime.path)
        XCTAssertNotEqual(try run(script, in: root, path: binaries.path + ":/usr/bin:/bin"), 0)
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing cli".utf8))
    }

    func testVerifiedClaudeCLIIsInstalledAtomicallyAndReused() throws {
        let root = try directory(), binaries = root.appendingPathComponent("bin")
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("claude-fixture")
        let fixtureData = Data("#!/bin/sh\nprintf '\(EdgeAgentService.claudeCodeVersion) (Claude Code)\\n'\n".utf8)
        try fixtureData.write(to: fixture)
        let digest = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
        let curl = "#!/bin/sh\nwhile [ \"$1\" != '-o' ]; do shift; done\ncp '\(fixture.path)' \"$2\"\n"
        for (name, script) in [
            "uname": "#!/bin/sh\nprintf 'x86_64\\n'\n",
            "curl": curl,
            "sha256sum": "#!/bin/sh\nexec /usr/bin/shasum -a 256 \"$@\"\n"
        ] {
            let file = binaries.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let script = EdgeAgentService.claudeInstallationScript
            .replacingOccurrences(of: "/opt/throttle-agent/runtime", with: runtime.path)
            .replacingOccurrences(
                of: "0399c793ff571d5946ef923d80b4f330d05ac4b6842a6b0775468f5d389403c0",
                with: digest
            )
        XCTAssertEqual(try run(script, in: root, path: binaries.path + ":/usr/bin:/bin"), 0)
        let installed = runtime.appendingPathComponent("claude-\(EdgeAgentService.claudeCodeVersion)")
        XCTAssertEqual(try Data(contentsOf: installed), fixtureData)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".local/bin/claude")), fixtureData)

        let curlPath = binaries.appendingPathComponent("curl")
        try "#!/bin/sh\nexit 99\n".write(to: curlPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curlPath.path)
        XCTAssertEqual(try run(script, in: root, path: binaries.path + ":/usr/bin:/bin"), 0)
    }
}
