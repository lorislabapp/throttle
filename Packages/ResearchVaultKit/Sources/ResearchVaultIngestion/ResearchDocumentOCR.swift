import CoreGraphics
import CoreML
import Vision

/// A single document's OCR session. A failed accelerator must not cause one
/// failing accelerator attempt per page, nor change OCR policy process-wide.
struct ResearchDocumentOCR {
    private var requiresCPU = false

    mutating func text(in image: CGImage) throws -> String? {
        do {
            return try perform(image, cpuOnly: requiresCPU)
        } catch {
            guard !requiresCPU else { throw error }
            // Retry once using only devices Vision advertises for this request.
            // Empty recognition is not an engine failure and is never retried.
            requiresCPU = true
            return try perform(image, cpuOnly: true)
        }
    }

    private func perform(_ image: CGImage, cpuOnly: Bool) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["fr-FR", "en-US"]
        if cpuOnly {
            let stages = try request.supportedComputeStageDevices
            guard !stages.isEmpty else { throw OCRFailure.cpuUnavailable }
            for (stage, devices) in stages {
                guard let cpu = devices.first(where: {
                    if case .cpu = $0 { return true }
                    return false
                }) else { throw OCRFailure.cpuUnavailable }
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private enum OCRFailure: Error { case cpuUnavailable }
}
