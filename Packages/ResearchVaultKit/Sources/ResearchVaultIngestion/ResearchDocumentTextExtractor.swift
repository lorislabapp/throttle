#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Foundation
import PDFKit
import Vision

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
            return try pdfText(bytes, name: url.lastPathComponent)
        default:
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(
                url.lastPathComponent
            )
        }
    }

    /// A page whose text layer yields less than this is treated as scanned.
    /// Matches the threshold the DeepSearsh PDF tool has used in production.
    private static let ocrMinimumCharacters = 20

    /// Extract a PDF's text, falling back to on-device OCR for scanned pages.
    ///
    /// Previously this returned only the embedded text layer and threw when every
    /// page was empty, so a scanned PDF was rejected outright — silently absent
    /// from the corpus rather than visibly unreadable. Scanned pages contributing
    /// nothing is the single most-cited cause of disappointing retrieval, and the
    /// sibling DeepSearsh pipeline already solved it with Vision.
    ///
    /// Rendering goes through CoreGraphics rather than PDFPage.thumbnail, which is
    /// AppKit-backed: this package also targets iOS, and the vault agent runs as a
    /// background helper with no UI session.
    private static func pdfText(_ bytes: Data, name: String) throws -> String {
        guard let document = PDFDocument(data: bytes) else {
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(name)
        }
        var pages: [String] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= ocrMinimumCharacters {
                pages.append(embedded)
                continue
            }
            if let recognised = recogniseText(in: bytes, pageIndex: index),
               !recognised.isEmpty {
                pages.append(recognised)
            } else if !embedded.isEmpty {
                pages.append(embedded)
            }
        }
        guard !pages.isEmpty else {
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(name)
        }
        return pages.joined(separator: "\n\n")
    }

    /// Render one page and read it with Vision. Returns nil rather than throwing:
    /// a page that yields nothing is reported as empty, never dropped silently.
    private static func recogniseText(in bytes: Data, pageIndex: Int) -> String? {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: pageIndex + 1) else { return nil }

        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let width = Int((box.width * scale).rounded())
        let height = Int((box.height * scale).rounded())
        guard width > 0, height > 0, width * height < 40_000_000 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The corpus is bilingual; a French-only or English-only pass loses half.
        request.recognitionLanguages = ["fr-FR", "en-US"]
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
