import Foundation
import CryptoKit

/// Content-addressed blob store for CMV pointers (Chantier 2). When the trimmer
/// replaces a bulky payload (a base64 image, an oversized tool_result) with a
/// text pointer, the original bytes are stored here keyed by their SHA-256. The
/// pointer carries that hash, so `throttle_expand_pointer` can rehydrate the exact
/// original on demand — the trim is reversible per-block, not only via the
/// whole-file backup. Content-addressing means identical payloads dedupe to one
/// blob across every session.
enum ContentStore {

    /// Override-able for tests; defaults to the app-support store.
    nonisolated(unsafe) static var baseDir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Throttle/cmv-store", isDirectory: true)

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Store `data`; returns its SHA-256 hex. Idempotent: identical bytes map to
    /// the same blob and are written once. Best-effort — a write failure still
    /// returns the hash (the pointer text stays informative even if a later
    /// expand misses).
    @discardableResult
    static func put(_ data: Data) -> String {
        let hash = sha256Hex(data)
        let url = baseDir.appendingPathComponent("\(hash).blob")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return hash
    }

    /// Fetch the original bytes for a hash, or nil if never stored / expired.
    static func get(_ hash: String) -> Data? {
        let clean = hash.lowercased().filter(\.isHexDigit)
        guard clean.count == 64 else { return nil }
        return try? Data(contentsOf: baseDir.appendingPathComponent("\(clean).blob"))
    }

    /// Age out blobs older than `maxAge` (default 30 days). These can contain
    /// secrets from trimmed tool output, so they expire; the whole-file Throttle
    /// backup remains the long-term recovery path. Called on launch.
    static func purge(maxAge: TimeInterval = 30 * 86_400) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for f in files where f.pathExtension == "blob" {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mod < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
