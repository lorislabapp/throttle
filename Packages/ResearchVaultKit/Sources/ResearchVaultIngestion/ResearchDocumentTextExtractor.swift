#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics
import Foundation
import PDFKit

public enum ResearchDocumentTextExtractorError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedOrUnreadable(String)
    case ocrUnavailable(String, page: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOrUnreadable(let name):
            return "Unsupported or unreadable document: \(name)."
        case .ocrUnavailable(let name, let page):
            return "Local OCR is unavailable for page \(page) of \(name). The document was not imported."
        }
    }
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
        var unreadablePages = 0
        var ocr = ResearchDocumentOCR()
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= ocrMinimumCharacters {
                pages.append(embedded)
                continue
            }
            let recognised: String?
            do {
                recognised = try recogniseText(in: bytes, pageIndex: index, ocr: &ocr)
            } catch {
                // An unavailable engine is not evidence that the page is blank.
                // Do not seal a partial import as a successfully read document.
                throw ResearchDocumentTextExtractorError.ocrUnavailable(name, page: index + 1)
            }
            if let recognised,
               !recognised.isEmpty {
                pages.append(recognised)
            } else if !embedded.isEmpty {
                pages.append(embedded)
            } else {
                // A page that yields nothing must leave a mark. Joining silently
                // over it makes an unreadable page indistinguishable from one that
                // never existed, and the receipt then seals that shortfall as a
                // legitimate character count — the same "absent rather than
                // visibly unreadable" failure this fallback exists to remove,
                // moved down from the document to the page.
                unreadablePages += 1
                pages.append("[page \(index + 1): no text layer and OCR recovered nothing]")
            }
        }
        guard pages.count > unreadablePages else {
            throw ResearchDocumentTextExtractorError.unsupportedOrUnreadable(name)
        }
        return pages.joined(separator: "\n\n")
    }

    /// Nil means no recoverable text; a thrown error means OCR was unavailable.
    private static func recogniseText(
        in bytes: Data, pageIndex: Int, ocr: inout ResearchDocumentOCR
    ) throws -> String? {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: pageIndex + 1) else { return nil }

        let box = page.getBoxRect(.mediaBox)
        // The media box comes from the file and CoreGraphics does not clamp it.
        // A declared page of 1e11 points overflows the pixel-count multiply and
        // traps the process before any guard can reject it — a 438-byte file is
        // enough, and since watched folders are re-scanned it would crash again
        // on every relaunch. Validate in Double, before any conversion to Int.
        let boxWidth = box.width.isFinite ? Double(box.width) : 0
        let boxHeight = box.height.isFinite ? Double(box.height) : 0
        guard boxWidth > 1, boxHeight > 1, boxWidth < 200_000, boxHeight < 200_000 else {
            return nil
        }

        // Fit the pixel budget by rendering smaller rather than giving up: a page
        // skipped here vanishes from the document silently, which is the failure
        // this whole fallback exists to remove.
        let budget = 24_000_000.0
        let scale = min(2.0, (budget / (boxWidth * boxHeight)).squareRoot())
        let width = Int(boxWidth * scale)
        let height = Int(boxHeight * scale)
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }

        return try ocr.text(in: image)
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
