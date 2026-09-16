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
        let directory = try resolved(relativeDirectory, allowRoot: true)
        let candidates = try candidateFiles(in: directory)
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
                    "matches": Self.maximumMatches
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

    private func candidateFiles(in directory: URL) throws -> (files: [URL], truncated: Bool) {
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw ProjectKnowledgeError.notDirectory }
        guard let enumerator = files.enumerator(atPath: directory.path) else {
            throw ProjectKnowledgeError.notDirectory
        }
        var result: [URL] = []
        while let path = enumerator.nextObject() as? String {
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            let url = directory.appendingPathComponent(path)
            if Self.isSensitivePath(relative(url)) {
                enumerator.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFDIR {
                if Self.excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if type == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            guard type == S_IFREG,
                  info.st_size <= Self.maximumFileBytes,
                  Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            result.append(url)
        }
        result.sort { relative($0) < relative($1) }
        return (Array(result.prefix(Self.maximumSearchFiles)), result.count > Self.maximumSearchFiles)
    }
}
