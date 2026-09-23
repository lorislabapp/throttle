import Darwin
import Foundation
import ThrottleShared

extension ProjectKnowledgeExplorer {
    func search(
        literal: String,
        within relativeDirectory: String = "",
        now: Date = Date()
    ) throws -> ProjectKnowledgeResult {
        guard !literal.isEmpty, literal.count <= 256 else {
            throw ProjectKnowledgeError.invalidRequest
        }
        let candidates = try candidateFiles(in: relativeDirectory)
        var accesses: [ProjectKnowledgeAccess] = []
        var matches: [String] = []
        var bytesRead = 0
        var redactions: [String] = []
        var truncated = candidates.truncated
        for url in candidates.files {
            if bytesRead >= Self.maximumSearchBytes || matches.count >= Self.maximumMatches {
                truncated = true
                break
            }
            let remainingBytes = Self.maximumSearchBytes - bytesRead
            let file: ProjectKnowledgeFile
            do {
                file = try readFile(relative(url), maximumBytes: remainingBytes)
            } catch {
                truncated = true
                continue
            }
            bytesRead += file.data.count
            redactions.append(contentsOf: OutboundPolicy.findings(in: file.text))
            accesses.append(searchAccess(file, url: url))
            appendMatches(literal: literal, file: file, into: &matches)
        }
        return searchResult(
            matches: matches,
            accesses: accesses,
            redactions: redactions,
            truncated: truncated,
            now: now
        )
    }

    private func searchResult(
        matches: [String],
        accesses: [ProjectKnowledgeAccess],
        redactions: [String],
        truncated: Bool,
        now: Date
    ) -> ProjectKnowledgeResult {
        var output = matches.isEmpty ? "(no exact matches)" : matches.joined(separator: "\n")
        let outputWasTruncated = output.count > Self.maximumOutputCharacters
        if outputWasTruncated {
            output = String(output.prefix(Self.maximumOutputCharacters))
        }
        return ProjectKnowledgeResult(
            text: output,
            receipt: receipt(
                operation: .search,
                accesses: accesses,
                redactions: redactions,
                truncated: truncated || outputWasTruncated,
                limits: [
                    "files": Self.maximumSearchFiles,
                    "bytes": Self.maximumSearchBytes,
                    "matches": Self.maximumMatches,
                    "visited_entries": Self.maximumVisitedEntries
                ],
                now: now
            )
        )
    }

    private func searchAccess(
        _ file: ProjectKnowledgeFile,
        url: URL
    ) -> ProjectKnowledgeAccess {
        ProjectKnowledgeAccess(
            path: relative(url),
            sha256: Self.sha256(file.data),
            bytesRead: file.data.count,
            firstLine: 1,
            lastLine: max(1, file.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        )
    }

    private func appendMatches(
        literal: String,
        file: ProjectKnowledgeFile,
        into matches: inout [String]
    ) {
        for (index, line) in file.text.components(separatedBy: .newlines).enumerated()
        where line.localizedCaseInsensitiveContains(literal) {
            let safeLine = OutboundPolicy.scrub(line)
            matches.append("\(relative(file.url)):\(index + 1):\(String(safeLine.prefix(300)))")
            if matches.count >= Self.maximumMatches { return }
        }
    }

    private func candidateFiles(in directory: String) throws -> (files: [URL], truncated: Bool) {
        var remaining = Self.maximumVisitedEntries
        var pending = [directory]
        var result: [URL] = []
        var truncated = false
        while let next = pending.popLast() {
            guard remaining > 0 else { return (result, true) }
            let entries: (values: [DirectoryEntry], truncated: Bool)
            do { entries = try directoryEntries(next, remaining: &remaining) } catch {
                if next == directory { throw error }
                truncated = true
                continue
            }
            truncated = truncated || entries.truncated
            for entry in entries.values {
                let url = root.appendingPathComponent(entry.path)
                if entry.isDirectory {
                    if !Self.excludedDirectories.contains(url.lastPathComponent),
                       entry.path.split(separator: "/").count < 32 {
                        pending.append(entry.path)
                    } else { truncated = true }
                } else if Self.allowedExtensions.contains(url.pathExtension.lowercased()) {
                    guard result.count < Self.maximumSearchFiles else { return (result, true) }
                    result.append(url)
                }
            }
        }
        return (result.sorted { relative($0) < relative($1) }, truncated)
    }
}
