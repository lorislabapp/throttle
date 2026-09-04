import CryptoKit
import Foundation
import ResearchVaultIngestion
import ResearchVaultModel

enum ResearchVaultURLIntakeError: Error, Equatable {
    case invalidScheme
    case blockedByPolicy(String)
    case responseTooLarge
    case unsupportedContent
    case emptyExtraction
}

struct ResearchVaultURLIntake {
    static let maximumBytes = 512 * 1_024
    private static let findingCharacters = 30_000

    static func receipt(
        url: URL,
        mimeType: String?,
        bytes: Data,
        projectKey: String,
        sensitivity: ResearchSensitivity
    ) throws -> ResearchReceipt {
        guard url.scheme?.lowercased() == "https" else {
            throw ResearchVaultURLIntakeError.invalidScheme
        }
        if let reason = WebURLPolicy.rejectionReason(for: url, resolveDNS: false) {
            throw ResearchVaultURLIntakeError.blockedByPolicy(reason)
        }
        guard bytes.count <= maximumBytes else {
            throw ResearchVaultURLIntakeError.responseTooLarge
        }

        let text = try extractedText(url: url, mimeType: mimeType, bytes: bytes)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ResearchVaultURLIntakeError.emptyExtraction }
        let bodyHash = sha256(bytes)
        let sourceID = "url-source"
        return try ResearchReceipt.seal(
            receiptID: ResearchReceiptDeterministicIdentity.uuid(
                for: "\(projectKey)\n\(url.absoluteString)\n\(bodyHash)"
            ),
            sessionID: "url-intake:" + String(bodyHash.prefix(16)),
            agentID: "throttle-url-intake-v1",
            projectKey: projectKey,
            question: "Imported URL: " + url.absoluteString,
            findings: chunks(trimmed, maximum: findingCharacters).map {
                ResearchFinding(claim: $0, status: .open, evidenceIDs: [sourceID])
            },
            sources: [
                ResearchSource(
                    id: sourceID,
                    kind: .url,
                    locator: url.absoluteString,
                    observedAt: Date(),
                    sha256: bodyHash
                )
            ],
            openQuestions: ["Imported source content has not been independently verified."],
            sensitivity: sensitivity
        )
    }

    private static func extractedText(url: URL, mimeType: String?, bytes: Data) throws -> String {
        let normalizedMIME = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedMIME == "text/html" || normalizedMIME == "application/xhtml+xml" {
            do {
                return try ResearchDocumentTextExtractor.extractText(
                    from: url.appendingPathExtension("html"),
                    bytes: bytes
                )
            } catch {
                throw ResearchVaultURLIntakeError.unsupportedContent
            }
        }
        guard normalizedMIME?.hasPrefix("text/") == true,
              let decoded = String(data: bytes, encoding: .utf8) else {
            throw ResearchVaultURLIntakeError.unsupportedContent
        }
        return decoded
    }

    static func fetch(
        url: URL,
        projectKey: String,
        sensitivity: ResearchSensitivity
    ) async throws -> ResearchReceipt {
        guard url.scheme?.lowercased() == "https" else {
            throw ResearchVaultURLIntakeError.invalidScheme
        }
        if let reason = WebURLPolicy.rejectionReason(for: url, resolveDNS: true) {
            throw ResearchVaultURLIntakeError.blockedByPolicy(reason)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(
            configuration: configuration,
            delegate: ResearchVaultURLRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html, text/plain;q=0.9, text/*;q=0.8", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let finalURL = http.url else {
            throw ResearchVaultURLIntakeError.unsupportedContent
        }
        if let reason = WebURLPolicy.rejectionReason(for: finalURL, resolveDNS: true) {
            throw ResearchVaultURLIntakeError.blockedByPolicy(reason)
        }
        if http.expectedContentLength > Int64(maximumBytes) {
            throw ResearchVaultURLIntakeError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(max(Int(http.expectedContentLength), 0), maximumBytes))
        for try await byte in stream {
            guard data.count < maximumBytes else {
                throw ResearchVaultURLIntakeError.responseTooLarge
            }
            data.append(byte)
        }
        return try receipt(
            url: finalURL,
            mimeType: http.mimeType,
            bytes: data,
            projectKey: projectKey,
            sensitivity: sensitivity
        )
    }

    private static func chunks(_ text: String, maximum: Int) -> [String] {
        var result: [String] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(
                remainder.startIndex,
                offsetBy: min(maximum, remainder.count)
            )
            var boundary = end
            if end < remainder.endIndex,
               let whitespace = remainder[..<end].lastIndex(where: { $0.isWhitespace }),
               remainder.distance(from: whitespace, to: end) < 2_000 {
                boundary = whitespace
            }
            let chunk = remainder[..<boundary]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            remainder = remainder[boundary...].drop(while: { $0.isWhitespace })
        }
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ResearchVaultURLRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let source = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let destination = request.url,
              source.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              source.host?.lowercased() == destination.host?.lowercased(),
              source.port == destination.port,
              WebURLPolicy.rejectionReason(for: destination, resolveDNS: true) == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
