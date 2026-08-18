import Foundation

/// On-machine benchmark of the embedded local model. The 2026-08 mix research
/// found no published benchmark for Throttle's real regime (M-series 16 GB,
/// heavy swap, concurrent agents) — so the user's own Mac is the only honest
/// source of numbers. One bounded run measures what the generic tables can't:
/// load time and end-to-end throughput *on this machine, under today's load*.
///
/// The tok/s figure is derived (chars/4) and mixes prefill + decode — it is an
/// `≈ est` everywhere it is shown, never a promise.
enum LocalModelBenchService {

    static let profileKey = "throttleLocalBenchProfile"

    struct Profile: Codable, Sendable, Equatable {
        let modelId: String
        let measuredAt: Date
        /// Cold-ish load: time until the runtime had a usable container.
        let loadSeconds: Double
        /// End-to-end generation over a ~4K-char source (prefill + decode mixed).
        let generateSeconds: Double
        let generatedCharacters: Int
        /// chars/4 heuristic — an estimate, labelled as such in every surface.
        var estTokensPerSecond: Double {
            guard generateSeconds > 0 else { return 0 }
            return Double(generatedCharacters) / 4.0 / generateSeconds
        }
    }

    static func loadProfile() -> Profile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    private static func store(_ profile: Profile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    /// A ~4K-char synthetic build log: repetitive developer evidence — the
    /// content class the local model is actually pointed at.
    private static var syntheticSource: String {
        var lines: [String] = []
        for i in 0..<60 {
            lines.append("[12:0\(i % 10):41] compile module Sample\(i).swift — ok (0.\(i % 9)s)")
            if i % 7 == 0 { lines.append("warning: unused variable 'value\(i)' in Sample\(i).swift:42") }
            if i % 13 == 0 { lines.append("error: cannot find type 'Widget\(i)' in scope — Sample\(i).swift:88") }
        }
        return lines.joined(separator: "\n")
    }

    /// Run one bounded measurement. Requires the embedded model to be installed;
    /// the caller must gate on memory pressure (never benchmark a swapping Mac —
    /// the number would be real but the run would worsen the very condition the
    /// product exists to relieve).
    static func run() async throws -> Profile {
        let loadStart = Date()
        // First touch loads the container; on a warm runtime this measures ~0,
        // which is honest too (that IS the current cost of using it).
        _ = try await EmbeddedModelRuntime.shared.delegate(
            source: "ready?", objective: "Reply with the single word: ready", kind: .classify,
            maxTokens: 8
        )
        let loadSeconds = Date().timeIntervalSince(loadStart)

        let genStart = Date()
        let result = try await EmbeddedModelRuntime.shared.delegate(
            source: syntheticSource,
            objective: "Count the error lines and list each error's file and line number.",
            kind: .extract,
            maxTokens: 256
        )
        let generateSeconds = Date().timeIntervalSince(genStart)

        let profile = Profile(
            modelId: EmbeddedModelRuntime.modelID,
            measuredAt: Date(),
            loadSeconds: loadSeconds,
            generateSeconds: generateSeconds,
            generatedCharacters: result.returnedCharacters
        )
        store(profile)
        return profile
    }
}
