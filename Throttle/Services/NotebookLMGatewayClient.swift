import Darwin
import Foundation

enum NotebookLMGatewayClientError: Error, Equatable {
    case unavailable
    case invalidConfiguration
    case launchFailed
    case timeout
    case responseTooLarge
    case invalidResponse
    case gatewayRejected(String)
}

actor NotebookLMGatewayClient: NotebookLMGatewayServing {
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let callTimeout: TimeInterval = 180

    private enum Tool: String {
        case listNotebooks = "nlm_list_notebooks"
        case listSources = "nlm_list_sources"
        case exportSource = "nlm_export_source"
    }

    private struct Command: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private let command: Command
    private let exportRoot: URL

    init(config: MCPServerConfig? = nil, exportRoot: URL? = nil) throws {
        let selected = config ?? MCPHealthService.servers().first {
            $0.name.lowercased() == "notebooklm-sota"
        }
        guard let selected else { throw NotebookLMGatewayClientError.unavailable }
        guard case let .stdio(executable, arguments, environment) = selected.transport,
              !executable.isEmpty,
              environment.keys.allSatisfy(Self.validEnvironmentKey) else {
            throw NotebookLMGatewayClientError.invalidConfiguration
        }
        command = Command(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        self.exportRoot = exportRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/NotebookLM", isDirectory: true)
    }

    func listNotebooks() async throws -> [NotebookLMNotebookDescriptor] {
        let data = try await call(.listNotebooks, arguments: [:])
        return try Self.decodeNotebooks(data)
    }

    func listSources(notebookURL: URL) async throws -> [NotebookLMSourceDescriptor] {
        let data = try await call(
            .listSources,
            arguments: ["notebookURL": notebookURL.absoluteString]
        )
        return try Self.decodeSources(data)
    }

    func exportSource(notebookURL: URL, index: Int) async throws -> NotebookLMSourceExport {
        guard index >= 0 else { throw NotebookLMGatewayClientError.invalidConfiguration }
        let data = try await call(
            .exportSource,
            arguments: ["notebookURL": notebookURL.absoluteString, "index": index]
        )
        return try Self.decodeExportReceipt(
            data,
            expectedNotebookURL: notebookURL,
            exportRoot: exportRoot
        )
    }

    private func call(_ tool: Tool, arguments: [String: Any]) async throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "exec " + ([command.executable] + command.arguments).map(Self.shellQuote).joined(separator: " ")
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, configured in
            configured
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw NotebookLMGatewayClientError.launchFailed
        }

        let request = try Self.request(tool: tool.rawValue, arguments: arguments)
        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            let response = try await Self.readResponse(
                from: output.fileHandleForReading,
                process: ProcessBox(process)
            )
            if process.isRunning { process.terminate() }
            return try Self.unwrap(response)
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private static func request(tool: String, arguments: [String: Any]) throws -> Data {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "Throttle", "version": "3.4.0"]
            ]
        ]
        let initialized: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ]
        let call: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        return try [initialize, initialized, call]
            .map { try JSONSerialization.data(withJSONObject: $0) + Data([0x0A]) }
            .reduce(into: Data()) { $0.append($1) }
    }

    private static func readResponse(
        from handle: FileHandle,
        process: ProcessBox
    ) async throws -> Data {
        return try await withTaskGroup(of: Result<Data, NotebookLMGatewayClientError>.self) { group in
            group.addTask {
                do {
                    return .success(try readLine(fileDescriptor: handle.fileDescriptor, responseID: 2))
                } catch let error as NotebookLMGatewayClientError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidResponse)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(callTimeout))
                if process.process.isRunning { process.process.terminate() }
                return .failure(.timeout)
            }
            let result = await group.next() ?? .failure(.invalidResponse)
            group.cancelAll()
            return result
        }.get()
    }

    nonisolated private static func readLine(
        fileDescriptor: Int32,
        responseID: Int
    ) throws -> Data {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                read(fileDescriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else { throw NotebookLMGatewayClientError.invalidResponse }
            buffer.append(contentsOf: chunk[0 ..< count])
            guard buffer.count <= maximumResponseBytes else {
                throw NotebookLMGatewayClientError.responseTooLarge
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if responseIdentifier(line) == responseID { return line }
            }
        }
    }

    private static func responseIdentifier(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

}

extension NotebookLMGatewayClient {

    static func unwrap(_ response: Data) throws -> Data {
        guard response.count <= maximumResponseBytes,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["id"] as? Int == 2 else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw NotebookLMGatewayClientError.gatewayRejected(error["message"] as? String ?? "unknown")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        if let structured = result["structuredContent"] as? [String: Any] {
            if structured["ok"] as? Bool == false {
                throw NotebookLMGatewayClientError.gatewayRejected(
                    structured["error"] as? String ?? "gateway rejected the request"
                )
            }
            let payload = structured["data"] ?? structured
            return try JSONSerialization.data(withJSONObject: payload)
        }
        if let content = result["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String,
           let data = text.data(using: .utf8) {
            return data
        }
        throw NotebookLMGatewayClientError.invalidResponse
    }

    static func decodeNotebooks(_ data: Data) throws -> [NotebookLMNotebookDescriptor] {
        let payload = try object(data)
        guard let rows = payload["notebooks"] as? [[String: Any]] else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        return try rows.map { row in
            guard let id = row["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let title = (row["title"] ?? row["name"]) as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rawURL = (row["notebookURL"] ?? row["url"]) as? String,
                  let url = URL(string: rawURL),
                  url.scheme == "https",
                  url.host?.lowercased() == "notebook.google.com",
                  let sourceCount = row["sourceCount"] as? Int,
                  sourceCount >= 0 else {
                throw NotebookLMGatewayClientError.invalidResponse
            }
            return NotebookLMNotebookDescriptor(
                id: id,
                title: title,
                url: url,
                sourceCount: sourceCount
            )
        }
    }

    static func decodeSources(_ data: Data) throws -> [NotebookLMSourceDescriptor] {
        let payload = try object(data)
        guard let rows = payload["sources"] as? [[String: Any]] else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        return try rows.enumerated().map { offset, row in
            guard let title = row["title"] as? String else {
                throw NotebookLMGatewayClientError.invalidResponse
            }
            return NotebookLMSourceDescriptor(
                index: row["index"] as? Int ?? offset,
                title: title,
                sourceID: (row["sourceId"] ?? row["id"]) as? String
            )
        }
    }

    static func decodeExport(_ data: Data) throws -> Data {
        guard data.count <= maximumResponseBytes else {
            throw NotebookLMGatewayClientError.responseTooLarge
        }
        if let payload = try? object(data) {
            for key in ["markdown", "content", "text"] {
                if let value = payload[key] as? String, let bytes = value.data(using: .utf8) {
                    return bytes
                }
            }
        } else if String(data: data, encoding: .utf8) != nil {
            return data
        }
        throw NotebookLMGatewayClientError.invalidResponse
    }

    static func decodeExportReceipt(
        _ data: Data,
        expectedNotebookURL: URL,
        exportRoot: URL
    ) throws -> NotebookLMSourceExport {
        let payload = try object(data)
        if let rawPath = payload["path"] as? String {
            guard payload["ok"] as? Bool == true,
                  let notebookID = payload["notebook"] as? String,
                  notebookID == expectedNotebookURL.lastPathComponent,
                  let title = payload["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NotebookLMGatewayClientError.invalidResponse
            }
            return NotebookLMSourceExport(
                markdown: try readExportFile(at: URL(fileURLWithPath: rawPath), root: exportRoot),
                title: title
            )
        }
        return NotebookLMSourceExport(markdown: try decodeExport(data))
    }

    private static func readExportFile(at fileURL: URL, root: URL) throws -> Data {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        let descriptor = open(filePath, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NotebookLMGatewayClientError.invalidResponse }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumResponseBytes else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = chunk.withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw NotebookLMGatewayClientError.invalidResponse }
            if count == 0 { return result }
            guard result.count + count <= maximumResponseBytes else {
                throw NotebookLMGatewayClientError.responseTooLarge
            }
            result.append(contentsOf: chunk[0 ..< count])
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotebookLMGatewayClientError.invalidResponse
        }
        return object
    }

    private static func validEnvironmentKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
