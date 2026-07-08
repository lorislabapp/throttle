import AppKit
import ImageIO
import Vision

/// On-device OCR for dropped image files. A screenshot costs ~4–5k vision
/// tokens; its extracted text is ~200–450 — so when the user drops an image
/// into the Cockpit terminal, optionally inject the OCR'd TEXT instead of the
/// image. Local, private, no network.
enum ImageTextExtractor {

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Token estimates (best-effort — labelled ≈ at the call site)

    /// Anthropic vision-token estimate for an image: `tokens ≈ (w × h) / 750`,
    /// after the same down-scale the API applies (long edge ≤ 1568 px, total
    /// ≤ ~1.15 MP). Returns 0 if dimensions can't be read.
    static func imageTokenEstimate(_ url: URL) -> Int {
        // Read pixel dimensions WITHOUT decoding the image (fast — keeps the
        // drop menu instant even for large screenshots).
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return 0 }
        var w = pw, h = ph
        guard w > 0, h > 0 else { return 0 }
        // Long-edge clamp.
        let longEdge = max(w, h)
        if longEdge > 1568 { let s = 1568 / longEdge; w *= s; h *= s }
        // Total-pixel clamp.
        let maxPixels = 1_150_000.0
        if w * h > maxPixels { let s = (maxPixels / (w * h)).squareRoot(); w *= s; h *= s }
        return Int((w * h / 750).rounded())
    }

    /// Token estimate for OCR'd text: ~4 characters per token.
    static func textTokenEstimate(_ text: String) -> Int {
        max(1, TokenEstimate.fromBytes(text.count, kind: .prose))   // OCR'd text is prose → ~4 bytes/token
    }

    /// Recognized text (lines joined), or nil if the image has none / can't load.
    /// Synchronous — call off the main thread.
    static func extractText(from url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }

        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
