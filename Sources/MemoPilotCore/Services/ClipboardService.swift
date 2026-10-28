import Foundation
import AppKit

public struct ClipboardPayload: Sendable, Equatable {
    public var text: String
    public var imagePath: String?

    public init(text: String, imagePath: String? = nil) {
        self.text = text
        self.imagePath = imagePath
    }
}

public enum ClipboardService {
    @MainActor
    public static func readPayload() -> ClipboardPayload? {
        let pb = NSPasteboard.general

        // 1. Check for text on the pasteboard
        if let rawString = pb.string(forType: .string) {
            let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ClipboardPayload(text: trimmed, imagePath: nil)
            }
        }

        // 2. Check for an image on the pasteboard (e.g. copied image from WeChat)
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoPilot-Capture-\(UUID().uuidString).png")
            do {
                try pngData.write(to: outputURL, options: .atomic)
                return ClipboardPayload(text: "", imagePath: outputURL.path)
            } catch {
                return nil
            }
        }

        return nil
    }
}
