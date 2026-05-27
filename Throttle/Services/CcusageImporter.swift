import Foundation
import GRDB

/// Imports Claude Code usage data from ccusage CLI tool.
///
/// Architecture:
/// 1. Detect if ccusage is installed (npx or global)
/// 2. Run `ccusage --json` to get aggregated usage data
/// 3. Parse JSON output (daily/weekly/monthly reports)
/// 4. Import into Throttle's SQLite DB (dedupe by conversation UUID)
///
/// ccusage JSON format (simplified):
/// ```json
/// {
///   "daily": [
///     {
///       "date": "2024-05-27",
///       "usage": {
///         "inputTokens": 123456,
///         "outputTokens": 45678,
///         "cacheCreationTokens": 12000,
///         "cacheReadTokens": 89000
///       },
///       "cost": 12.34,
///       "models": ["claude-opus-4-7", "claude-sonnet-4-6"]
///     }
///   ]
/// }
/// ```
actor CcusageImporter {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    enum ImportError: Error, LocalizedError {
        case ccusageNotFound
        case invalidJSON
        case noData
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ccusageNotFound:
                return "ccusage CLI not found. Install with: npx ccusage@latest"
            case .invalidJSON:
                return "Failed to parse ccusage JSON output"
            case .noData:
                return "No usage data found in ccusage output"
            case .executionFailed(let message):
                return "ccusage execution failed: \(message)"
            }
        }
    }

    /// Check if ccusage is available (either via npx or global install)
    func isCcusageAvailable() async -> Bool {
        // Try global install first
        let globalCheck = await runShellCommand("which ccusage")
        if globalCheck.success {
            return true
        }

        // Try npx (will succeed if npm is installed, even if ccusage isn't cached)
        let npxCheck = await runShellCommand("which npx")
        return npxCheck.success
    }

    /// Import usage data from ccusage into Throttle DB
    /// - Returns: Number of days imported
    @discardableResult
    func importFromCcusage() async throws -> Int {
        // 1. Check if ccusage is available
        guard await isCcusageAvailable() else {
            throw ImportError.ccusageNotFound
        }

        // 2. Run ccusage with JSON output
        let result = await runCcusageJSON()
        guard result.success, let jsonData = result.output.data(using: .utf8) else {
            throw ImportError.executionFailed(result.error ?? "Unknown error")
        }

        // 3. Parse JSON
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let report = try? decoder.decode(CcusageReport.self, from: jsonData) else {
            throw ImportError.invalidJSON
        }

        guard !report.daily.isEmpty else {
            throw ImportError.noData
        }

        // 4. Import each day into Throttle DB
        let imported = try await Task.detached { [database] in
            try database.write { db in
                var count = 0
                let dateFormatter = ISO8601DateFormatter()
                dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                dateFormatter.formatOptions = [.withFullDate]

                for day in report.daily {
                    // Parse ISO 8601 date (e.g., "2024-05-27") and set to noon UTC
                    guard let baseDate = dateFormatter.date(from: day.date) else {
                        continue
                    }

                    // Synthesize usage events (one per model, split tokens evenly)
                    let tokenPerModel = day.models.count
                    for model in day.models {
                        var event = UsageEvent(
                            id: nil,
                            sessionId: "ccusage-import-\(day.date)",
                            timestamp: Int64(baseDate.timeIntervalSince1970),
                            model: model,
                            inputTokens: day.usage.inputTokens / tokenPerModel,
                            outputTokens: day.usage.outputTokens / tokenPerModel,
                            cacheCreate: day.usage.cacheCreationTokens / tokenPerModel,
                            cacheRead: day.usage.cacheReadTokens / tokenPerModel,
                            serviceTier: nil
                        )
                        try event.insert(db)  // INSERT (will fail if duplicate sessionId+timestamp+model)
                        count += 1
                    }
                }
                return count
            }
        }.value

        return imported
    }

    /// Run ccusage CLI with JSON output
    private func runCcusageJSON() async -> ShellResult {
        // Try global ccusage first
        var result = await runShellCommand("ccusage --json")
        if result.success {
            return result
        }

        // Fall back to npx
        result = await runShellCommand("npx --yes ccusage@latest --json")
        return result
    }

    /// Run a shell command and return output/error
    private func runShellCommand(_ command: String) async -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8)

            return ShellResult(
                success: process.terminationStatus == 0,
                output: output,
                error: error
            )
        } catch {
            return ShellResult(
                success: false,
                output: "",
                error: error.localizedDescription
            )
        }
    }
}

// MARK: - Data Models

struct ShellResult {
    let success: Bool
    let output: String
    let error: String?
}

struct CcusageReport: Codable {
    let daily: [CcusageDailyEntry]
}

struct CcusageDailyEntry: Codable {
    let date: String  // ISO 8601 date string
    let usage: CcusageUsage
    let cost: Double
    let models: [String]
}

struct CcusageUsage: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    /// Weighted tokens (same formula as Throttle)
    var weightedTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + (cacheReadTokens / 10)
    }
}

// MARK: - Preview Support

#if DEBUG
extension CcusageImporter {
    /// Mock import for testing/preview
    static func mockImport() async throws -> Int {
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        return 14  // Pretend we imported 14 days
    }
}
#endif
