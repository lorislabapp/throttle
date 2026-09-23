import Darwin
import Foundation
@testable import Throttle

/// Only built by the isolated evidence harness, never linked into the app.
@main
struct VerificationCrashWorker {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(64) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let phase = CommandLine.arguments[2]
        guard root.lastPathComponent.hasPrefix("throttle-crash-fixture-"),
              ["before-attach", "after-attach"].contains(phase) else { exit(64) }
        let store = PlanStore(projectRoot: root)
        let lease = try TaskVerificationLifecycle.begin(taskID: "task", store: store,
            request: .init(command: "touch forbidden-marker", stamp: "fixture", author: "controller", timeout: 30))
        _ = TaskIntegrationService.shell("touch forbidden-marker", in: root, timeout: 5) { child in
            try String(child.pid).write(to: root.appendingPathComponent("child.pid"), atomically: true, encoding: .utf8)
            if phase == "after-attach" {
                guard let process = TaskVerificationProcess.captureAdmittedChild(child.pid) else { exit(65) }
                try TaskVerificationLifecycle.attachProcess(
                    taskID: "task", store: store, lease: lease, process: process)
            }
            // Deliberately bypass Swift deinit: only kernel descriptor closure
            // can release the gate. This simulates abrupt controller death.
            _exit(71)
        }
        exit(66)
    }
}
