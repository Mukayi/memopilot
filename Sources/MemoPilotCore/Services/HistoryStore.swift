import Foundation

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct AnyDecodableValue: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var results: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                results.append(item)
            } else {
                _ = try? container.decode(AnyDecodableValue.self)
            }
        }
        self.elements = results
    }
}

public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()

    public let storageURL: URL
    public let capturesDirectoryURL: URL
    private let lock = NSLock()

    public init(baseDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let baseDirectoryURL {
            baseDir = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            baseDir = appSupport.appendingPathComponent("MemoPilot", isDirectory: true)
        }
        self.storageURL = baseDir.appendingPathComponent("history.json")
        self.capturesDirectoryURL = baseDir.appendingPathComponent("Captures", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: capturesDirectoryURL, withIntermediateDirectories: true)
    }

    public var hasExistingHistoryFile: Bool {
        lock.withLock {
            FileManager.default.fileExists(atPath: storageURL.path)
        }
    }

    public func loadAll() -> [HistoryRecord] {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: storageURL.path),
                  let data = try? Data(contentsOf: storageURL),
                  !data.isEmpty else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            if let records = try? decoder.decode([HistoryRecord].self, from: data) {
                return records.sorted { $0.createdAt > $1.createdAt }
            }
            if let lossy = try? decoder.decode(LossyDecodableArray<HistoryRecord>.self, from: data),
               !lossy.elements.isEmpty {
                return lossy.elements.sorted { $0.createdAt > $1.createdAt }
            }

            // Back up corrupted file instead of silently losing it
            let backupURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("history.backup-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: storageURL, to: backupURL)
            return []
        }
    }

    public func saveAll(_ records: [HistoryRecord]) {
        lock.withLock {
            let sorted = records.sorted { $0.createdAt > $1.createdAt }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(sorted) else { return }
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    public func persistScreenshotIfNeeded(tempPath: String?) -> String? {
        lock.withLock {
            guard let tempPath, FileManager.default.fileExists(atPath: tempPath) else {
                return nil
            }
            if tempPath.hasPrefix(capturesDirectoryURL.path) {
                return tempPath
            }
            let destURL = capturesDirectoryURL.appendingPathComponent("Capture-\(UUID().uuidString).png")
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: tempPath), to: destURL)
                if tempPath.contains("MemoPilot-Capture-") {
                    try? FileManager.default.removeItem(atPath: tempPath)
                }
                return destURL.path
            } catch {
                return tempPath
            }
        }
    }

    public func removeSavedImageIfOwned(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        lock.withLock {
            if path.hasPrefix(capturesDirectoryURL.path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
