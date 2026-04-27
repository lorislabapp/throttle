import Foundation

struct SessionFileParseResult: Sendable {
    let events: [UsageEvent]
    let bytesRead: Int64    // total bytes consumed including the starting offset
}

enum SessionFileParser {
    /// Parses a JSONL file from `fromByteOffset` to EOF. Returns extracted events
    /// and the new total file offset (i.e. EOF). Safe on partial last lines —
    /// they are skipped and re-parsed next time.
    static func parse(url: URL, fromByteOffset: Int64) throws -> SessionFileParseResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(fromByteOffset))

        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else {
            return SessionFileParseResult(events: [], bytesRead: fromByteOffset)
        }

        var events: [UsageEvent] = []
        var consumedOffsetWithinSlice: Int = 0
        let slice = data
        var lineStart = 0
        let bytes = [UInt8](slice)

        for i in 0..<bytes.count {
            if bytes[i] == 0x0A { // newline
                let lineData = slice.subdata(in: lineStart..<i)
                if let line = String(data: lineData, encoding: .utf8),
                   let event = try? UsageExtractor.extract(fromLine: line) {
                    events.append(event)
                }
                lineStart = i + 1
                consumedOffsetWithinSlice = i + 1
            }
        }

        let newAbsoluteOffset = fromByteOffset + Int64(consumedOffsetWithinSlice)
        return SessionFileParseResult(events: events, bytesRead: newAbsoluteOffset)
    }
}
