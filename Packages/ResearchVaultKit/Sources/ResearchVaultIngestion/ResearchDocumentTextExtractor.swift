#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Foundation
import PDFKit

public enum ResearchDocumentTextExtractorError: Error, Equatable, Sendable {
    case unsupportedOrUnreadable(String)
}

public enum ResearchDocumentTextExtractor {
    public static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "csv", "json", "jsonl", "html", "htm",
        "rtf", "docx", "pdf"
    ]

    public static func extractText(from url: URL, bytes: Data) throws -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "csv", "json", "jsonl":
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(
                    url.lastPathComponent
                )
            }
            return text
        case "html", "htm":
            return try attributedText(bytes, type: .html, name: url.lastPathComponent)
        case "rtf":
            return try attributedText(bytes, type: .rtf, name: url.lastPathComponent)
        case "docx":
            return try attributedText(bytes, type: .officeOpenXML, name: url.lastPathComponent)
        case "pdf":
            guard let document = PDFDocument(data: bytes) else {
                throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(
                    url.lastPathComponent
                )
            }
            let pages = (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }
            guard !pages.isEmpty else {
                throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(
                    url.lastPathComponent
                )
            }
            return pages.joined(separator: "\n\n")
        default:
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(
                url.lastPathComponent
            )
        }
    }

    private static func attributedText(
        _ bytes: Data,
        type: NSAttributedString.DocumentType,
        name: String
    ) throws -> String {
        do {
            return try NSAttributedString(
                data: bytes,
                options: [
                    .documentType: type,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ).string
        } catch {
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(name)
        }
    }
}
