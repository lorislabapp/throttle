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
    /// ≈ image-token cost re-charged on resume (~3000 tok/image, Opus/Fable scale).
    var tokens: Int { images * 3000 }
    static let empty = ContextBloat(images: 0, sessions: 0)
}

enum ContextBloatService {
    static func scan() -> ContextBloat {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects").path

        // Count embedded image blocks ("media_type":"image…") across transcripts.
        let images = grepCount(["-rohE", "\"media_type\":\"image", projects])
        guard images > 0 else { return .empty }
        // Files that contain at least one embedded image = affected sessions.
        let sessions = grepCount(["-rlE", "\"media_type\":\"image", projects])
        return ContextBloat(images: images, sessions: sessions)
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
