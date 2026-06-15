import AppKit
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
