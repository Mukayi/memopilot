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
    private static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "bmp", "gif"]

    @MainActor
    public static func readPayload() -> ClipboardPayload? {
        let pb = NSPasteboard.general

        // 1. If the user copied an image file in Finder, Finder also puts the filename in .string.
        //    Check for copied file URLs first so we use the actual image file rather than its filename string!
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            if let firstImageURL = fileURLs.first(where: {
                supportedImageExtensions.contains($0.pathExtension.lowercased())
            }), FileManager.default.fileExists(atPath: firstImageURL.path) {
                return ClipboardPayload(text: "", imagePath: firstImageURL.path)
            }
            // Non-image file copied in Finder: do not rasterize its Finder file icon as an image
            return nil
        }

        // 2. Check for copied bitmap image data (e.g. screenshot or copied image from WeChat)
        let imagePath = readBitmapImageFromPasteboardIfPresent(pb)

        // 3. Check for plain text on the pasteboard
        let trimmedText = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedText.isEmpty || imagePath != nil {
            return ClipboardPayload(text: trimmedText, imagePath: imagePath)
        }

        return nil
    }

    @MainActor
    public static func readImageFromPasteboardIfPresent() -> String? {
        let pb = NSPasteboard.general
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !fileURLs.isEmpty {
            if let firstImageURL = fileURLs.first(where: {
                supportedImageExtensions.contains($0.pathExtension.lowercased())
            }), FileManager.default.fileExists(atPath: firstImageURL.path) {
                return firstImageURL.path
            }
            return nil
        }
        return readBitmapImageFromPasteboardIfPresent(pb)
    }

    @MainActor
    private static func readBitmapImageFromPasteboardIfPresent(_ pb: NSPasteboard) -> String? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard pb.availableType(from: imageTypes) != nil,
              let image = NSImage(pasteboard: pb) else {
            return nil
        }
        return saveNSImageToTempPNG(image)
    }

    public static func saveNSImageToTempPNG(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoPilot-Capture-\(UUID().uuidString).png")
        do {
            try pngData.write(to: outputURL, options: .atomic)
            return outputURL.path
        } catch {
            return nil
        }
    }
}
