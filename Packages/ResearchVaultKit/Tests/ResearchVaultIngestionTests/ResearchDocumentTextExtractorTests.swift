import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import ResearchVaultIngestion

@Suite("Research document text extraction")
struct ResearchDocumentTextExtractorTests {

    /// A scanned page has no text layer at all, so the extractor used to throw
    /// and the document vanished from the corpus without ever being reported as
    /// unreadable. This builds a genuinely scanned-shaped PDF — the words are
    /// rasterised into a bitmap first, then that bitmap is the only thing drawn
    /// into the page — so there is nothing for PDFKit to read and only OCR can
    /// recover it.
    @Test("reads a scanned PDF that carries no text layer")
    func scannedPDFIsRecoveredByOCR() throws {
        let phrase = "CHIFFREMENT DE LA BASE"
        let pdf = try scannedPDF(text: phrase)

        let extracted = try ResearchDocumentTextExtractor.extractText(
            from: URL(fileURLWithPath: "/tmp/scanned.pdf"), bytes: pdf
        )

        let normalised = extracted.uppercased()
        // OCR is not required to be perfect on synthetic input; requiring the
        // longest, most distinctive word keeps the test about the fallback
        // firing rather than about recognition accuracy.
        #expect(
            normalised.contains("CHIFFREMENT"),
            "OCR fallback should recover text from a page with no text layer, got: \(extracted)"
        )
    }

    @Test("a PDF with a real text layer never pays for OCR")
    func textLayerIsUsedDirectly() throws {
        let pdf = try textLayerPDF(text: "Le coffre de recherche conserve la provenance exacte.")
        let extracted = try ResearchDocumentTextExtractor.extractText(
            from: URL(fileURLWithPath: "/tmp/text.pdf"), bytes: pdf
        )
        #expect(extracted.contains("provenance"))
    }

    @Test("an unreadable PDF is still reported, not silently empty")
    func unreadablePDFThrows() {
        let notAPDF = Data("this is not a pdf".utf8)
        #expect(throws: ResearchDocumentTextExtractorError.self) {
            _ = try ResearchDocumentTextExtractor.extractText(
                from: URL(fileURLWithPath: "/tmp/broken.pdf"), bytes: notAPDF
            )
        }
    }

    // MARK: - Fixtures

    /// Words rasterised into a bitmap, then that bitmap drawn as the page's only
    /// content — no glyphs, no text layer, exactly like a scan.
    private func scannedPDF(text: String) throws -> Data {
        // Rasterise 1:1 with the page. Downscaling the bitmap into a smaller page
        // and letting the extractor upscale it again destroys the glyph edges OCR
        // needs, which says nothing about the fallback and everything about the
        // fixture.
        let size = CGSize(width: 1_000, height: 260)
        guard let bitmap = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw FixtureError.contextUnavailable }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(origin: .zero, size: size))
        draw(text: text, in: bitmap, at: CGPoint(x: 40, y: 110), pointSize: 64)
        guard let image = bitmap.makeImage() else { throw FixtureError.contextUnavailable }

        return try pdfData(size: size) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    private func textLayerPDF(text: String) throws -> Data {
        let size = CGSize(width: 612, height: 200)
        return try pdfData(size: size) { context in
            draw(text: text, in: context, at: CGPoint(x: 24, y: 100), pointSize: 18)
        }
    }

    private func pdfData(size: CGSize, _ body: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw FixtureError.contextUnavailable
        }
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FixtureError.contextUnavailable
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        body(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func draw(text: String, in context: CGContext, at origin: CGPoint, pointSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    private enum FixtureError: Error { case contextUnavailable }
}
