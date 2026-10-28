import Foundation
import Vision
import AppKit

public enum VisionOCRService {
    public static func recognizeText(at imagePath: String) -> String {
        let fileURL = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return ""
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        do {
            let handler = VNImageRequestHandler(url: fileURL, options: [:])
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            // Fallback to NSImage -> CGImage if URL initializer fails
            guard let nsImage = NSImage(contentsOfFile: imagePath),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return ""
            }
            let fallbackHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? fallbackHandler.perform([request])
            let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            return lines.joined(separator: "\n")
        }
    }
}
