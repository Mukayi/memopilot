import Foundation

public enum ScreenCaptureService {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var isCapturing: Bool = false

    public static func captureInteractiveRegion() async throws -> String? {
        let shouldStart: Bool = lock.withLock {
            if isCapturing { return false }
            isCapturing = true
            return true
        }
        guard shouldStart else { return nil }
        defer {
            lock.withLock { isCapturing = false }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoPilot-Capture-\(UUID().uuidString).png")

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", outputURL.path]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            if FileManager.default.fileExists(atPath: outputURL.path) {
                return outputURL.path
            }
            return nil
        }.value
    }
}
