import Foundation

/// Golden-dataset benchmark for the tokopt hook — turns "tokopt saves ~X%" from a
/// claim into a MEASURED, reproducible number. Runs a fixed corpus of representative
/// tool outputs through the exact live pipeline (`shouldCompress` gate → `compress`
/// → the 15%-gain guard) and reports the real byte/≈token reduction per sample. Also
/// proves the safety invariants hold (a failing run and a JSON array must be no-ops),
/// so a recipe that silently stops compressing — or starts mangling — is caught.
enum TokoptBenchmark {

    struct Sample: Sendable, Equatable {
        let name: String
        let command: String
        let baselineBytes: Int
        let compressedBytes: Int
        let compressed: Bool           // did the live gate actually apply a trim?
        var reductionPct: Double { baselineBytes == 0 ? 0 : Double(baselineBytes - compressedBytes) / Double(baselineBytes) * 100 }
        var estTokensSaved: Int { TokenEstimate.fromBytes(max(0, baselineBytes - compressedBytes), kind: .dense) }   // CLI output → dense ratio
    }

    struct Report: Sendable, Equatable {
        let samples: [Sample]
        var totalBaseline: Int { samples.reduce(0) { $0 + $1.baselineBytes } }
        var totalCompressed: Int { samples.reduce(0) { $0 + $1.compressedBytes } }
        var overallReductionPct: Double { totalBaseline == 0 ? 0 : Double(totalBaseline - totalCompressed) / Double(totalBaseline) * 100 }
        var estTokensSaved: Int { samples.reduce(0) { $0 + $1.estTokensSaved } }
        var compressedCount: Int { samples.filter(\.compressed).count }
    }

    /// Run every corpus sample through the EXACT live pipeline and measure.
    static func run() -> Report {
        Report(samples: corpus.map { item in
            let baseline = item.output.utf8.count
            let (bytes, applied) = liveResult(stdout: item.output, command: item.command)
            return Sample(name: item.name, command: item.command,
                          baselineBytes: baseline, compressedBytes: bytes, compressed: applied)
        })
    }

    /// Mirror TokoptHook.run()'s decision exactly: gate → compress → require ≥15% gain.
    private static func liveResult(stdout: String, command: String) -> (bytes: Int, applied: Bool) {
        let baseline = stdout.utf8.count
        guard TokoptHook.shouldCompress(stdout: stdout, stderr: "") else { return (baseline, false) }
        let c = TokoptHook.compress(stdout, command: command)
        guard c.utf8.count < (baseline * 85) / 100 else { return (baseline, false) }   // <15% gain → no-op
        return (c.utf8.count, true)
    }

    // MARK: - Golden corpus (fixed + reproducible)

    static let corpus: [(name: String, command: String, output: String)] = {
        // A large green cargo suite — the headline test-runner recipe case.
        let cargoGreen = "   Compiling app v0.1.0\n    Finished test [unoptimized] in 1.2s\n\nrunning 180 tests\n"
            + (0..<180).map { "test mod::case_\($0) ... ok" }.joined(separator: "\n")
            + "\n\ntest result: ok. 180 passed; 0 failed; 0 ignored; finished in 0.42s\n"

        // A failing cargo suite — MUST be a no-op (safety invariant).
        let cargoFail = "running 3 tests\ntest a ... ok\ntest b ... FAILED\n\nfailures:\n\n---- b stdout ----\nthread 'b' panicked at 'boom'\n\ntest result: FAILED. 2 passed; 1 failed; finished in 0.01s\n"

        // git status with the instructional hint lines tokopt strips. Sized past
        // the live 1 KB minimum (a busy working tree — where compression matters).
        let gitModified = (0..<24).map { "\tmodified:   src/module_\($0)/component.swift" }.joined(separator: "\n")
        let gitUntracked = (0..<12).map { "\tsrc/new/generated_\($0).swift" }.joined(separator: "\n")
        let gitStatus = """
        On branch main
        Your branch is up to date with 'origin/main'.

        Changes not staged for commit:
          (use "git add <file>..." to update what will be committed)
          (use "git restore <file>..." to discard changes in working directory)
        \(gitModified)

        Untracked files:
          (use "git add <file>..." to include in what will be committed)
        \(gitUntracked)

        no changes added to commit (use "git add" and/or "git commit -a")
        """

        // npm install chatter (progress lines get stripped, warnings kept).
        let npmInstall = "npm install\n"
            + (0..<40).map { "fetching package-\($0)@1.0.0" }.joined(separator: "\n")
            + "\nnpm warn deprecated foo@1.0.0: use bar\nadded 240 packages in 3s\n"

        // A JSON array — MUST be a no-op (never corrupt structured output).
        let jsonArray = "[" + (0..<50).map { "{\"id\":\($0),\"ok\":true}" }.joined(separator: ",") + "]"

        return [
            ("cargo test (green)", "cargo test", cargoGreen),
            ("cargo test (fail)",  "cargo test", cargoFail),
            ("git status",         "git status", gitStatus),
            ("npm install",        "npm install", npmInstall),
            ("json array",         "gh api /x", jsonArray),
        ]
    }()
}
