import Foundation

/// First, safe brick of CMV (context virtualization): detect base64 IMAGES
/// embedded in session transcripts. These are pure mechanical bloat — the
/// model's text description of the image stays in the conversation, but the raw
/// base64 is re-sent (and re-charged as image tokens, 2700-4800 each on Opus/
/// Fable) on every resume/branch. Stripping them is losslessly safe (no user or
/// assistant reasoning touched). v1 detects + quantifies; trimming a snapshot is
/// a later phase that writes a NEW file, never edits the live transcript.
struct ContextBloat: Sendable {
    let images: Int
    let sessions: Int
    /// ≈ trimmable tokens from oversized tool_result dumps (lossless: the
    /// assistant's own summary of the output stays; only the raw dump is stubbed).
    let toolResultTokens: Int
    /// ≈ image-token cost re-charged on resume (~3000 tok/image, Opus/Fable scale).
    var imageTokens: Int { images * 3000 }
    var totalTokens: Int { imageTokens + toolResultTokens }
    static let empty = ContextBloat(images: 0, sessions: 0, toolResultTokens: 0)
}

enum ContextBloatService {
    /// A tool_result line longer than this carries a trimmable raw dump.
    private static let bigLine = 6000
    /// Chars kept as a stub when trimming (path/command metadata + head).
    private static let stub = 300

    static func scan() -> ContextBloat {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path

        // Count embedded image blocks ("media_type":"image…") across transcripts.
        let images = grepCount(["-rohE", "\"media_type\":\"image", projects])
        let sessions = images > 0 ? grepCount(["-rlE", "\"media_type\":\"image", projects]) : 0
        let toolBloat = toolResultBloat()
        guard images > 0 || toolBloat > 0 else { return .empty }
        return ContextBloat(images: images, sessions: sessions, toolResultTokens: toolBloat)
    }

    /// Sum trimmable chars from oversized tool_result lines in recent transcripts.
    /// Only lines that ARE tool_results are counted — user/assistant prose is never
    /// touched, keeping the trim lossless. Bounded to recent files for speed.
    private static func toolResultBloat() -> Int {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let all = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        let recent = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.prefix(60)

        var trimmableChars = 0
        for url in recent {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") where line.count > bigLine && line.contains("\"tool_result\"") {
                trimmableChars += line.count - stub
            }
        }
        return trimmableChars / 4   // ≈ 4 chars/token
    }

    /// Run grep and return the number of output lines.
    private static func grepCount(_ args: [String]) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? 0 : text.split(separator: "\n").count
    }
}
