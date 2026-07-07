import Foundation
import Network
import Compression
import GRDB

/// In-process OTLP/HTTP receiver on 127.0.0.1:4318. Accepts Claude Code's
/// telemetry export (`POST /v1/logs`, `POST /v1/metrics`), decodes the logs
/// batch with `TraycerDecoder`, and writes skill / command / decision events to
/// `traycer_events` keyed by `session.id` — which joins by equality to the
/// token/cost rows already in `usage_events`.
///
/// **Measure-only / fail-open by construction.** It only listens; it never
/// rewrites or forwards. A bind conflict (a user's own collector already owns
/// 4318), a malformed body, or a DB error disables the offending path quietly —
/// Claude Code's telemetry export is never disturbed, so the app can't break the
/// tool it measures.
///
/// Cloned from `MCPProxyServer`'s NWListener bind + manual `\r\n\r\n` HTTP
/// framing (the one proven-under-hardened-runtime `import Network` in the repo),
/// extended for what the OTLP exporter actually sends: **chunked** transfer
/// encoding and **gzip** bodies (both observed empirically against Claude Code
/// v2.1.202 — a Content-Length-only reader captured 0 bytes).
/// `@unchecked Sendable`: all mutable state (`listener`, `writer`, `isListening`)
/// is confined to the serial `q` — `writer` is set once in `start()` before any
/// connection can arrive, and `listener`/`isListening` are only touched from `q`'s
/// handlers. No cross-actor mutation races.
final class TraycerReceiver: @unchecked Sendable {

    /// Shared instance — one receiver per app. AppDelegate starts it at launch
    /// (if opted in); the Settings toggle starts/stops the same instance live.
    static let shared = TraycerReceiver()

    private let port: UInt16
    private let q = DispatchQueue(label: "throttle.traycer.otlp")
    private var listener: NWListener?
    private var writer: (any DatabaseWriter)?
    private(set) var isListening = false

    init(port: UInt16 = 4318) { self.port = port }

    // MARK: - Lifecycle

    /// Bind and start serving. Fail-open: any bind failure logs and returns with
    /// `isListening == false` — never throws, never crashes.
    func start(writer: any DatabaseWriter) {
        guard listener == nil else { return }
        self.writer = writer

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            log("bind failed on \(port) — receiver disabled (another collector?)")
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:  self?.isListening = true
            case .failed, .cancelled:
                self?.isListening = false
                self?.listener = nil
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            conn.start(queue: self.q)
            self.serve(conn)
        }
        listener.start(queue: q)
        log("listening on 127.0.0.1:\(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("throttle traycer: \(msg)\n".utf8))
    }

    // MARK: - One HTTP connection (keep-alive; one request at a time)

    private func serve(_ conn: NWConnection, carry: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = carry
            if let data { buffer.append(data) }

            guard let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: buffer) else {
                if isComplete || error != nil { conn.cancel() }
                else { self.serve(conn, carry: buffer) }
                return
            }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let bodyStart = headerEnd.upperBound

            // Frame the body: Content-Length OR chunked. Returns nil until complete.
            guard let (body, leftover) = self.framedBody(header: header, buffer: buffer, bodyStart: bodyStart) else {
                if isComplete || error != nil { conn.cancel() }
                else { self.serve(conn, carry: buffer) }
                return
            }

            let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ").map(String.init)
            let method = parts.first ?? ""
            let path = parts.count > 1 ? parts[1] : ""

            // gunzip if the exporter compressed (belt-and-suspenders: the env
            // installer also asks for no compression, but a user override wins).
            let decoded = Self.headerValue("content-encoding", in: header)?.lowercased() == "gzip"
                ? (Self.gunzip(body) ?? Data()) : body

            self.route(method: method, path: path, body: decoded)

            conn.send(content: Self.ok200, completion: .contentProcessed { _ in
                self.serve(conn, carry: leftover)   // keep-alive for the next export
            })
        }
    }

    // MARK: - Routing

    private func route(method: String, path: String, body: Data) {
        guard method == "POST", !body.isEmpty else { return }
        // Only /v1/logs carries skill/command/decision events. /v1/metrics
        // (cost.usage / token.usage) is intentionally dropped: token & cost
        // already live in usage_events from the JSONL watcher, and attribution
        // joins on session.id — decoding OTLP metrics too would double-count.
        guard path.hasSuffix("/v1/logs") else { return }
        let events = TraycerDecoder.decodeLogs(body)
        guard !events.isEmpty, let writer else { return }
        _ = TraycerStore.insert(events, into: writer)   // fail-open inside
    }

    // MARK: - Body framing (Content-Length | chunked)

    /// Returns `(body, leftover)` once the full body has arrived, else nil.
    private func framedBody(header: String, buffer: Data, bodyStart: Data.Index) -> (Data, Data)? {
        if let cl = Self.headerValue("content-length", in: header).flatMap({ Int($0) }) {
            let have = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard have >= cl else { return nil }
            let end = buffer.index(bodyStart, offsetBy: cl)
            return (buffer.subdata(in: bodyStart..<end), buffer.subdata(in: end..<buffer.endIndex))
        }
        if Self.headerValue("transfer-encoding", in: header)?.lowercased().contains("chunked") == true {
            return Self.dechunk(buffer, from: bodyStart)
        }
        return nil
    }

    /// Decode HTTP/1.1 chunked encoding starting at `from`. Returns the assembled
    /// body plus any pipelined leftover, or nil while still incomplete.
    private static func dechunk(_ data: Data, from: Data.Index) -> (Data, Data)? {
        var out = Data()
        var i = from
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = range(of: crlf, in: data, from: i) else { return nil }
            let sizeLine = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // Terminal chunk. Consume the trailing CRLF (ignore any trailers).
                if let trailerEnd = range(of: crlf, in: data, from: dataStart) {
                    return (out, data.subdata(in: trailerEnd.upperBound..<data.endIndex))
                }
                return nil
            }
            guard let dataEnd = data.index(dataStart, offsetBy: size, limitedBy: data.endIndex),
                  dataEnd < data.endIndex else { return nil }
            out.append(data.subdata(in: dataStart..<dataEnd))
            // Skip the CRLF that follows each chunk's data.
            guard let next = data.index(dataEnd, offsetBy: 2, limitedBy: data.endIndex) else { return nil }
            i = next
        }
    }

    // MARK: - gzip inflate (Compression / raw DEFLATE)

    /// Inflate a gzip member. Returns nil on a non-gzip or malformed blob
    /// (caller falls back to an empty body → the batch is skipped, never crashes).
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var off = 10
        if flags & 0x04 != 0 {                              // FEXTRA
            guard off + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
            off += 2 + xlen
        }
        if flags & 0x08 != 0 { off = skipCString(bytes, off) }   // FNAME
        if flags & 0x10 != 0 { off = skipCString(bytes, off) }   // FCOMMENT
        if flags & 0x02 != 0 { off += 2 }                        // FHCRC
        guard off < bytes.count - 8 else { return nil }

        // ISIZE (uncompressed size mod 2^32) from the last 4 bytes, little-endian.
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8) | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        let dstCap = max(isize, 64 * 1024)

        let deflate = data.subdata(in: data.index(data.startIndex, offsetBy: off)..<data.endIndex)
        var dst = Data(count: dstCap)
        let produced = dst.withUnsafeMutableBytes { dstRaw -> Int in
            deflate.withUnsafeBytes { srcRaw -> Int in
                guard let d = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let s = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, dstCap, s, deflate.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { return nil }
        return dst.prefix(produced)
    }

    private static func skipCString(_ bytes: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        return i + 1
    }

    // MARK: - HTTP helpers (shared shape with MCPProxyServer)

    private static let ok200 = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}".utf8)

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func range(of needle: Data, in haystack: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = from ?? haystack.startIndex
        guard i <= haystack.endIndex else { return nil }
        let end = haystack.index(haystack.endIndex, offsetBy: -needle.count)
        while i <= end {
            if haystack[i..<haystack.index(i, offsetBy: needle.count)].elementsEqual(needle) {
                return i..<haystack.index(i, offsetBy: needle.count)
            }
            i = haystack.index(after: i)
        }
        return nil
    }
}
