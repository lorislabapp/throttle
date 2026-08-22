import Foundation

/// CMV brick 3 — the **Surgical Context Trimmer**.
///
/// A user-invoked, lossless-by-construction trim of a SAVED session transcript
/// (`~/.claude/projects/<proj>/<sessionId>.jsonl`) so that `claude --resume`
/// reloads a lighter file.
///
/// The core safety guarantee: **it never deletes a line.** Line count, every
/// `uuid` / `parentUuid` / `tool_use_id`, and the entire reply chain stay
/// identical. It only shrinks payload INSIDE two content classes that are pure
/// mechanical bloat re-charged on every resume:
///   • base64 image blocks            → a schema-valid text pointer,
///   • (opt-in) oversized tool_result → a head-preserving stub.
/// Every line it does not transform is copied **verbatim from the original raw
/// bytes** (zero collateral mutation — no key reordering, no whitespace drift).
///
/// `transformLine` is a pure function, so `preview` (read-only) and `apply`
/// (writes) share it exactly: the preview is the apply, minus the write. Before
/// anything is written the result is validated to re-parse line-for-line with
/// identical `type` + `uuid`; any failure ABORTS with no write. The original is
/// always backed up first, so every apply is reversible.
enum ContextTrimmerService {

    // MARK: - Options & results

    struct Options: Sendable {
        /// Replace base64 image blocks with a text pointer. Safe + high value.
        var trimImages: Bool = true
        /// If set, `tool_result` text longer than this many UTF-8 bytes is
        /// stubbed to its head. nil = off (the conservative default — stubbing a
        /// tool result is lossless for *reasoning* only because the assistant's
        /// summary remains, so it stays opt-in).
        var stubToolResultsOver: Int?
        /// If set, the bulky string INPUTS of write-oriented tool_use blocks
        /// (`content` / `old_string` / `new_string` of Write/Edit/…) longer than
        /// this many UTF-8 bytes are stubbed. Lossless for reasoning: the file is
        /// already on disk and the whitelist metadata (`file_path`, `command`)
        /// stays, so the model still knows what was written where. Opt-in.
        var stubToolInputsOver: Int?
        /// Replace text from events superseded by the latest compaction boundary
        /// while retaining their structural envelope and dependency identifiers.
        var trimSupersededEvents: Bool = false

        static let safe = Options(trimImages: true, stubToolResultsOver: nil)
        /// Full three-pass CMV mode. Raw mechanical tool output is archived once
        /// it exceeds 500 bytes, matching the context-cost threshold in the CMV
        /// doctrine; write payloads retain the more conservative 4 KB threshold.
        static let aggressive = Options(trimImages: true, stubToolResultsOver: 500,
                                        stubToolInputsOver: 4_000,
                                        trimSupersededEvents: true)
    }

    struct Plan: Sendable {
        let sessionURL: URL
        let totalLines: Int
        let imagesTrimmed: Int
        let imageBytesSaved: Int       // raw base64 UTF-8 bytes removed
        let toolResultsStubbed: Int
        let toolResultBytesSaved: Int
        var toolInputsStubbed: Int = 0
        var toolInputBytesSaved: Int = 0
        var supersededEventsTrimmed: Int = 0
        var supersededBytesSaved: Int = 0
        /// Whole-transcript size and last write — the two inputs the cache
        /// break-even needs. Filled in by `scanCandidates`; zero elsewhere, which
        /// makes `breakEven` return nil rather than a number built on nothing.
        var transcriptBytes: Int = 0
        var lastModified: Date?

        var bytesSaved: Int {
            imageBytesSaved + toolResultBytesSaved + toolInputBytesSaved + supersededBytesSaved
        }
        var isEmpty: Bool {
            imagesTrimmed == 0 && toolResultsStubbed == 0 &&
            toolInputsStubbed == 0 && supersededEventsTrimmed == 0
        }
        /// Rough re-charge estimate: images cost image-tokens (~1500 each on the
        /// Opus/Fable scale, not chars/4), tool payload costs ≈ chars/4.
        var estTokensSaved: Int {
            imagesTrimmed * 1_500 +
            TokenEstimate.fromBytes(toolResultBytesSaved + toolInputBytesSaved + supersededBytesSaved,
                                    kind: .dense)
        }

        /// How many turns of lighter reads this trim needs before it pays for the
        /// cache it forfeits. nil when the inputs aren't known (see `transcriptBytes`).
        func breakEven(now: Date = Date()) -> CacheBreakEven.Verdict? {
            guard transcriptBytes > 0, let modified = lastModified else { return nil }
            return CacheBreakEven.evaluate(
                prefixTokens: TokenEstimate.fromBytes(transcriptBytes),
                trimmableTokens: estTokensSaved,
                lastActivity: modified,
                now: now
            )
        }

        /// First 8 chars of the session UUID — enough to recognise a session.
        var sessionShort: String {
            String(sessionURL.deletingPathExtension().lastPathComponent.prefix(8))
        }
        /// Readable project from the encoded dir, e.g.
        /// "-Users-kevinnadjarian-GitHub-Throttle" → "Throttle".
        var projectLabel: String {
            let dir = sessionURL.deletingLastPathComponent().lastPathComponent
            let parts = dir.split(separator: "-").filter { !$0.isEmpty }
            return parts.last.map(String.init) ?? dir
        }
    }

    enum TrimError: LocalizedError {
        case unreadable(String)
        case activeSession
        case nothingToTrim
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let p):     return "Couldn’t read the transcript at \(p)."
            case .activeSession:         return "That session is currently active. Trim only past sessions — resume the lighter copy afterwards."
            case .nothingToTrim:         return "Nothing trimmable in this session."
            case .validationFailed(let why): return "Aborted to protect your data — the trimmed result failed validation (\(why)). Nothing was written."
            }
        }
    }

    // MARK: - Paths

    private static var backupsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/throttle-backups", isDirectory: true)
    }

    // MARK: - Public API

    /// Find the heaviest trimmable PAST sessions (image-bearing transcripts,
    /// excluding the active session and anything touched in the last 60 s).
    /// Cheap by construction: greps for image-bearing files first (small set),
    /// then previews only those. Sorted by bytes saved, capped to `limit`.
    static func scanCandidates(excludingSessionId: String?, limit: Int = 8,
                               options: Options = .safe, minIdleSeconds: TimeInterval = 60) -> [Plan] {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path
        var plans: [Plan] = []
        let paths = options.stubToolResultsOver == nil &&
            options.stubToolInputsOver == nil && !options.trimSupersededEvents
            ? grepImageBearingFiles(projects)
            : transcriptFiles(projects)
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            if let ex = excludingSessionId, ex == stem { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let mod = values?.contentModificationDate,
               Date().timeIntervalSince(mod) < minIdleSeconds { continue }
            guard var p = try? preview(url, options: options), !p.isEmpty else { continue }
            // Carry the whole-file facts so the row can say whether trimming pays now.
            p.transcriptBytes = values?.fileSize ?? 0
            p.lastModified = values?.contentModificationDate
            plans.append(p)
        }
        return Array(plans.sorted { $0.bytesSaved > $1.bytesSaved }.prefix(limit))
    }

    /// Read-only. Computes exactly what `apply` would save, writing nothing.
    static func preview(_ url: URL, options: Options = .safe) throws -> Plan {
        try buildTrimmed(url, options).1
    }

    /// Write a sidecar trimmed snapshot next to the original for inspection.
    /// Does NOT replace the original (so `--resume` still loads the original).
    /// Validates before writing; throws and writes nothing on any failure.
    @discardableResult
    static func writeSnapshot(_ url: URL, options: Options = .safe) throws -> (url: URL, plan: Plan) {
        // Persist trimmed originals so the snapshot's pointers stay expandable.
        // Fail the whole apply if a payload could not be stored: the pointer we
        // are about to write into the transcript would refer to nothing, and the
        // trim advertises itself as reversible. Better to refuse than to leave a
        // transcript that cannot be rehydrated.
        var storeFailed = false
        let (lines, plan) = try buildTrimmed(url, options, sink: { _, data in
            if ContentStore.put(data) == nil { storeFailed = true }
        })
        if storeFailed {
            throw TrimError.validationFailed("content store write failed (disk full?); nothing was changed")
        }
        guard !plan.isEmpty else { throw TrimError.nothingToTrim }
        let out = url.deletingPathExtension()
            .appendingPathExtension("throttle-trimmed.jsonl")
        try writeAtomically(lines, to: out)
        return (out, plan)
    }

    /// Reversible apply: back up the original to `~/.claude/throttle-backups`,
    /// then atomically replace it with the trimmed content. Refuses the active
    /// session and any file touched in the last 60 s (a live-session proxy).
    @discardableResult
    static func apply(_ url: URL, options: Options = .safe, currentSessionId: String? = nil,
                      minIdleSeconds: TimeInterval = 60) throws -> (plan: Plan, backup: URL) {
        let stem = url.deletingPathExtension().lastPathComponent
        if let cur = currentSessionId, cur == stem { throw TrimError.activeSession }
        if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(mod) < minIdleSeconds { throw TrimError.activeSession }

        // Persist each trimmed payload to the content store BEFORE replacing the
        // file, so every pointer in the new transcript is rehydratable.
        // Fail the whole apply if a payload could not be stored: the pointer we
        // are about to write into the transcript would refer to nothing, and the
        // trim advertises itself as reversible. Better to refuse than to leave a
        // transcript that cannot be rehydrated.
        var storeFailed = false
        let (lines, plan) = try buildTrimmed(url, options, sink: { _, data in
            if ContentStore.put(data) == nil { storeFailed = true }
        })
        if storeFailed {
            throw TrimError.validationFailed("content store write failed (disk full?); nothing was changed")
        }
        guard !plan.isEmpty else { throw TrimError.nothingToTrim }

        // 1) Back up the original BEFORE touching it.
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = backupsDir.appendingPathComponent("\(stem)-\(stamp).jsonl")
        try FileManager.default.copyItem(at: url, to: backup)

        // 2) Atomically replace the original with the validated trimmed content.
        try writeAtomically(lines, to: url)

        // 3) Post-write byte-verify (FileEditor-style hardening): read the file back
        // and confirm it round-trips to exactly the lines we intended. On any drift
        // (disk glitch, encoding surprise), restore the backup and abort — never
        // leave a half-written transcript that `--resume` would choke on.
        let readBack = (try? readLines(url)) ?? []
        if readBack != lines {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: backup, to: url)
            throw TrimError.validationFailed("post-write read-back mismatch; original restored")
        }
        return (plan, backup)
    }

    /// Opt-in automatic pass: trim the heaviest idle PAST transcripts in one go.
    /// Reuses the exact lossless+reversible `apply` path (backup + validation +
    /// rehydratable pointers), just without a manual button. Conservative by
    /// default — a 10-min idle floor so a session you're actively resuming is never
    /// touched, images-only (`.safe`), best-effort per file. Returns the totals for
    /// a single summary notification. Never throws.
    @discardableResult
    static func autoTrimIdle(minIdleSeconds: TimeInterval = 600,
                             options: Options = .safe,
                             limit: Int = 24) -> (count: Int, bytesSaved: Int, tokensSaved: Int) {
        var count = 0, bytes = 0, tokens = 0
        for plan in scanCandidates(excludingSessionId: nil, limit: limit,
                                   options: options, minIdleSeconds: minIdleSeconds) {
            guard let r = try? apply(plan.sessionURL, options: options,
                                     currentSessionId: nil, minIdleSeconds: minIdleSeconds) else { continue }
            count += 1; bytes += r.plan.bytesSaved; tokens += r.plan.estTokensSaved
        }
        return (count, bytes, tokens)
    }

    // MARK: - Core (pure transform + validation)

    private struct Counters {
        var images = 0, imageBytes = 0, stubs = 0, stubBytes = 0, inStubs = 0, inBytes = 0
        var superseded = 0, supersededBytes = 0
        mutating func add(_ o: Counters) {
            images += o.images; imageBytes += o.imageBytes
            stubs += o.stubs; stubBytes += o.stubBytes
            inStubs += o.inStubs; inBytes += o.inBytes
            superseded += o.superseded; supersededBytes += o.supersededBytes
        }
        func plan(url: URL, totalLines: Int) -> Plan {
            Plan(sessionURL: url, totalLines: totalLines,
                 imagesTrimmed: images, imageBytesSaved: imageBytes,
                 toolResultsStubbed: stubs, toolResultBytesSaved: stubBytes,
                 toolInputsStubbed: inStubs, toolInputBytesSaved: inBytes,
                 supersededEventsTrimmed: superseded,
                 supersededBytesSaved: supersededBytes)
        }
    }

    /// Pass 2 output: a dependency ledger plus the latest compaction boundary.
    /// The exact ID multisets are validated again after pass 3.
    private struct DependencyLedger {
        var toolUseIDs: [String] = []
        var toolResultIDs: [String] = []
        var latestBoundaryIndex: Int?
        var preservedUUIDs: Set<String> = []
    }

    /// Write-oriented tools whose bulky string inputs are pure resume bloat — the
    /// file already exists on disk, so stubbing the payload loses nothing for the
    /// model's reasoning. The metadata whitelist (file_path/command/…) is untouched.
    private static let writeToolInputs: [String: [String]] = [
        "Write": ["content"], "Edit": ["old_string", "new_string"],
        "NotebookEdit": ["new_source"]
    ]   // MultiEdit's `edits` array is handled separately (nested old/new strings).

    private struct LineOutcome { var line: String; var counters = Counters() }

    /// Pure: maps one raw transcript line to its (possibly rewritten) form.
    /// Falls back to the verbatim input on ANY ambiguity — losslessness wins.
    private static func transform(_ raw: String, _ opt: Options, superseded: Bool = false,
                                  _ sink: PointerSink? = nil) -> LineOutcome {
        // Cheap byte gate: only parse lines that could carry a trimmable payload.
        let mayImage = opt.trimImages && raw.contains("\"base64\"")
        let mayTR = opt.stubToolResultsOver != nil && raw.contains("\"tool_result\"")
        let mayInput = opt.stubToolInputsOver != nil && raw.contains("\"tool_use\"")
        guard mayImage || mayTR || mayInput || superseded else { return LineOutcome(line: raw) }

        guard let data = raw.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var message = obj["message"] as? [String: Any]
        else { return LineOutcome(line: raw) }   // not a shape we touch → verbatim

        if superseded, let text = message["content"] as? String, !text.isEmpty {
            var c = Counters()
            c.superseded = 1
            c.supersededBytes = text.utf8.count
            message["content"] = pointerText(text, label: "superseded pre-compaction event", sink: sink)
            obj["message"] = message
            guard let newData = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
                  let newLine = String(data: newData, encoding: .utf8) else {
                return LineOutcome(line: raw)
            }
            return LineOutcome(line: newLine, counters: c)
        }

        guard var content = message["content"] as? [[String: Any]]
        else { return LineOutcome(line: raw) }

        var c = Counters()
        var changed = false

        for i in content.indices {
            let type = content[i]["type"] as? String

            // A compacted-away prose block is no longer part of Claude's
            // preserved context. Archive it, but keep tool blocks below intact
            // so tool_use/tool_result dependency IDs remain structurally valid.
            if superseded, type == "text", let text = content[i]["text"] as? String,
               !text.isEmpty {
                c.superseded += 1; c.supersededBytes += text.utf8.count
                content[i]["text"] = pointerText(text, label: "superseded pre-compaction event",
                                                  sink: sink)
                changed = true
                continue
            }

            // (a) image block directly in message.content
            if mayImage, type == "image",
               let src = content[i]["source"] as? [String: Any],
               src["type"] as? String == "base64",
               let b64 = src["data"] as? String {
                c.images += 1; c.imageBytes += b64.utf8.count
                content[i] = imagePointer(mediaType: src["media_type"] as? String ?? "image",
                                          base64: b64, sink: sink)
                changed = true
                continue
            }

            // (c) tool_use — stub the bulky write-tool string inputs (file is on disk)
            if mayInput, type == "tool_use", let lim = opt.stubToolInputsOver,
               let name = content[i]["name"] as? String,
               var input = content[i]["input"] as? [String: Any] {
                var inChanged = false
                for field in writeToolInputs[name] ?? [] {
                    if let s = input[field] as? String, s.utf8.count > lim {
                        c.inStubs += 1; c.inBytes += s.utf8.count
                        input[field] = stubText(s, sink: sink); inChanged = true
                    }
                }
                if name == "MultiEdit", var edits = input["edits"] as? [[String: Any]] {
                    var eChanged = false
                    for k in edits.indices {
                        for field in ["old_string", "new_string"] {
                            if let s = edits[k][field] as? String, s.utf8.count > lim {
                                c.inStubs += 1; c.inBytes += s.utf8.count
                                edits[k][field] = stubText(s, sink: sink); eChanged = true
                            }
                        }
                    }
                    if eChanged { input["edits"] = edits; inChanged = true }
                }
                if inChanged { content[i]["input"] = input; changed = true }
                continue
            }

            // (b) tool_result — content is a String, or a list that can nest images/text
            if type == "tool_result" {
                if let str = content[i]["content"] as? String,
                   let lim = opt.stubToolResultsOver, str.utf8.count > lim {
                    c.stubs += 1; c.stubBytes += str.utf8.count
                    content[i]["content"] = stubText(str, sink: sink)
                    changed = true
                } else if var sub = content[i]["content"] as? [[String: Any]] {
                    var subChanged = false
                    for j in sub.indices {
                        let st = sub[j]["type"] as? String
                        if mayImage, st == "image",
                           let src = sub[j]["source"] as? [String: Any],
                           src["type"] as? String == "base64",
                           let b64 = src["data"] as? String {
                            c.images += 1; c.imageBytes += b64.utf8.count
                            sub[j] = imagePointer(mediaType: src["media_type"] as? String ?? "image",
                                                  base64: b64, sink: sink)
                            subChanged = true
                        } else if let lim = opt.stubToolResultsOver, st == "text",
                                  let t = sub[j]["text"] as? String, t.utf8.count > lim {
                            c.stubs += 1; c.stubBytes += t.utf8.count
                            sub[j]["text"] = stubText(t, sink: sink)
                            subChanged = true
                        }
                    }
                    if subChanged { content[i]["content"] = sub; changed = true }
                }
            }
        }

        guard changed else { return LineOutcome(line: raw) }

        message["content"] = content
        obj["message"] = message
        guard let newData = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let newLine = String(data: newData, encoding: .utf8) else {
            // Re-serialization failed → keep the original line, drop the counters.
            return LineOutcome(line: raw)
        }
        return LineOutcome(line: newLine, counters: c)
    }

    /// Build the full trimmed line array + plan, and VALIDATE it before returning.
    /// Throws (writing nothing) if any invariant is violated.
    private static func buildTrimmed(_ url: URL, _ opt: Options, sink: PointerSink? = nil) throws -> ([String], Plan) {
        let original = try readLines(url)
        // Pass 1 — byte scan. This deliberately does no JSON work and identifies
        // only lines that can carry mechanical bloat or compaction metadata.
        let candidates = Set(original.indices.filter { index in
            let line = original[index]
            return (opt.trimImages && line.contains("\"base64\"")) ||
                (opt.stubToolResultsOver != nil && line.contains("\"tool_result\"")) ||
                (opt.stubToolInputsOver != nil && line.contains("\"tool_use\"")) ||
                (opt.trimSupersededEvents &&
                    (line.contains("\"message\"") || line.contains("\"compactMetadata\"")))
        })

        // Pass 2 — dependency/compaction map.
        let ledger = dependencyLedger(original)
        var output = [String](); output.reserveCapacity(original.count)
        var counters = Counters()

        // Pass 3 — payload stripping. Lines outside pass 1 stay byte-verbatim.
        for (index, line) in original.enumerated() {
            guard candidates.contains(index) else {
                output.append(line)
                continue
            }
            let isSuperseded: Bool
            if opt.trimSupersededEvents, let boundary = ledger.latestBoundaryIndex,
               index < boundary, let uuid = topLevelUUID(line) {
                isSuperseded = !ledger.preservedUUIDs.contains(uuid)
            } else {
                isSuperseded = false
            }
            let o = transform(line, opt, superseded: isSuperseded, sink)
            output.append(o.line)
            counters.add(o.counters)
        }

        // Invariant 1 — no line added or dropped.
        guard output.count == original.count else {
            throw TrimError.validationFailed("line count changed (\(original.count)→\(output.count))")
        }
        // Invariant 2 — every output line re-parses, and any line we rewrote keeps
        // its top-level `type` + `uuid` (structural identity preserved).
        for (i, line) in output.enumerated() where line != original[i] {
            guard let nd = line.data(using: .utf8),
                  let nObj = (try? JSONSerialization.jsonObject(with: nd)) as? [String: Any]
            else { throw TrimError.validationFailed("line \(i) no longer parses as JSON") }
            guard let od = original[i].data(using: .utf8),
                  let oObj = (try? JSONSerialization.jsonObject(with: od)) as? [String: Any]
            else { continue }
            if (nObj["uuid"] as? String) != (oObj["uuid"] as? String) {
                throw TrimError.validationFailed("line \(i) uuid changed")
            }
            if (nObj["type"] as? String) != (oObj["type"] as? String) {
                throw TrimError.validationFailed("line \(i) type changed")
            }
        }
        let outputLedger = dependencyLedger(output)
        guard outputLedger.toolUseIDs == ledger.toolUseIDs else {
            throw TrimError.validationFailed("tool_use dependency IDs changed")
        }
        guard outputLedger.toolResultIDs == ledger.toolResultIDs else {
            throw TrimError.validationFailed("tool_result dependency IDs changed")
        }

        return (output, counters.plan(url: url, totalLines: original.count))
    }

    private static func dependencyLedger(_ lines: [String]) -> DependencyLedger {
        var ledger = DependencyLedger()
        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if let compact = obj["compactMetadata"] as? [String: Any] {
                ledger.latestBoundaryIndex = index
                var preserved = Set<String>()
                if let messages = compact["preservedMessages"] as? [String: Any] {
                    for key in ["uuids", "allUuids"] {
                        for uuid in messages[key] as? [String] ?? [] { preserved.insert(uuid) }
                    }
                    if let anchor = messages["anchorUuid"] as? String { preserved.insert(anchor) }
                }
                if let segment = compact["preservedSegment"] as? [String: Any] {
                    for key in ["headUuid", "anchorUuid", "tailUuid"] {
                        if let uuid = segment[key] as? String { preserved.insert(uuid) }
                    }
                }
                ledger.preservedUUIDs = preserved
            }
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String { ledger.toolUseIDs.append(id) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { ledger.toolResultIDs.append(id) }
                default:
                    break
                }
            }
        }
        return ledger
    }

    private static func topLevelUUID(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj["uuid"] as? String
    }

    // MARK: - Pointer / stub builders

    /// A pointer-persistence sink: `(sha256Hex, originalBytes)`. nil on preview/
    /// scan (read-only, nothing persisted); set on apply/snapshot so the bytes
    /// land in the ContentStore and the pointer's hash can later rehydrate them.
    /// The pointer TEXT is identical regardless (the hash is a pure function of
    /// the bytes), so preview stays byte-for-byte what apply produces.
    typealias PointerSink = (String, Data) -> Void

    private static func imagePointer(mediaType: String, base64 b64: String, sink: PointerSink?) -> [String: Any] {
        let data = Data(b64.utf8)
        let hash = ContentStore.sha256Hex(data)
        sink?(hash, data)
        let kb = max(1, b64.utf8.count * 3 / 4 / 1024)   // base64 → raw bytes ≈ ×3/4
        return ["type": "text",
                "text": "[image removed by Throttle — \(mediaType), ≈\(kb) KB. Rehydrate the original with throttle_expand_pointer(throttle_id: \"\(hash)\"), or resume the Throttle backup.]"]
    }

    private static func stubText(_ s: String, sink: PointerSink?) -> String {
        let data = Data(s.utf8)
        let hash = ContentStore.sha256Hex(data)
        sink?(hash, data)
        let head = String(s.prefix(280))
        let kb = max(1, s.utf8.count / 1024)
        return head + "\n…[trimmed by Throttle — \(kb) KB removed. Rehydrate the full output with throttle_expand_pointer(throttle_id: \"\(hash)\"), or resume the backup.]"
    }

    private static func pointerText(_ text: String, label: String, sink: PointerSink?) -> String {
        let data = Data(text.utf8)
        let hash = ContentStore.sha256Hex(data)
        sink?(hash, data)
        return "[\(label) stripped by Throttle; SHA-256 \(hash). Rehydrate exactly with throttle_expand_pointer(throttle_id: \"\(hash)\"), or resume the backup.]"
    }

    // MARK: - IO

    private static func readLines(_ url: URL) throws -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TrimError.unreadable(url.path)
        }
        // Preserve every line including blanks; transcripts are LF-delimited.
        var lines = text.components(separatedBy: "\n")
        // A trailing newline yields a final empty element — drop only that one so
        // we round-trip the file shape (we re-join with "\n" + trailing newline).
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func writeAtomically(_ lines: [String], to url: URL) throws {
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `grep -rlE '"media_type":"image'` — the cheap pre-filter to the small set
    /// of transcripts that actually carry images before any full preview.
    private static func grepImageBearingFiles(_ dir: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = ["-rlE", "\"media_type\":\"image", dir]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".jsonl") }
    }

    /// Full CMV scans need transcripts without images too. Enumeration is still
    /// metadata-only; byte parsing remains deferred to the explicit pass 1.
    private static func transcriptFiles(_ dir: String) -> [String] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir),
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".jsonl") }
    }
}
