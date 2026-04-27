import Foundation
import GRDB
import OSLog

struct ColdStartScanner {
    let database: any DatabaseWriter
    private let logger = Logger(subsystem: "com.lorislab.throttle", category: "ColdStartScanner")

    init(database: any DatabaseWriter) {
        self.database = database
    }

    /// Scans every `.jsonl` file under `rootDirectory`, parsing only the bytes
    /// not yet seen (tracked via file_state). Idempotent — a re-scan of an
    /// unchanged file inserts nothing.
    func scan(rootDirectory: URL) throws {
        let files = Self.discoverJsonlFiles(under: rootDirectory)
        logger.info("Scanning \(files.count, privacy: .public) jsonl files under \(rootDirectory.path, privacy: .public)")

        for file in files {
            try scanFile(file)
        }
    }

    private func scanFile(_ url: URL) throws {
        // Normalise to strip `/private` prefix that FileManager.enumerator
        // adds on macOS — keeps file_state keys stable regardless of
        // whether the caller passes /var/... or /private/var/...
        let normalizedPath = url.standardizedFileURL.path

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let priorOffset: Int64 = try database.read { db in
            try FileState.fetchOne(db, key: normalizedPath)?.lastOffset ?? 0
        }

        let result = try SessionFileParser.parse(url: url, fromByteOffset: priorOffset)
        guard !result.events.isEmpty || result.bytesRead != priorOffset else {
            return
        }

        try database.write { db in
            for var event in result.events {
                try event.insert(db)
            }
            try DatabaseQueries.upsertFileState(
                in: db,
                path: normalizedPath,
                offset: result.bytesRead,
                mtime: Int64(mtime)
            )
        }
    }

    static func discoverJsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "jsonl" {
                results.append(url)
            }
        }
        return results
    }
}
