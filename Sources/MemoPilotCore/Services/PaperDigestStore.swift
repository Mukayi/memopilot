import Foundation

private struct LossyPaperRecordArray: Decodable {
    var elements: [PaperDigestRecord]

    private struct DummyVal: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var results: [PaperDigestRecord] = []
        while !container.isAtEnd {
            if let item = try? container.decode(PaperDigestRecord.self) {
                results.append(item)
            } else {
                _ = try? container.decode(DummyVal.self)
            }
        }
        self.elements = results
    }
}

public final class PaperDigestStore: @unchecked Sendable {
    public static let shared = PaperDigestStore()

    public let storageURL: URL
    private let lock = NSLock()
    private static let exportFolderDefaultsKey = "MemoPilot.paperMarkdownExportDirectory"

    public init(baseDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let baseDirectoryURL {
            baseDir = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            baseDir = appSupport.appendingPathComponent("MemoPilot", isDirectory: true)
        }
        self.storageURL = baseDir.appendingPathComponent("paper_digests.json")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    public var hasExistingStoreFile: Bool {
        lock.withLock {
            FileManager.default.fileExists(atPath: storageURL.path)
        }
    }

    public var savedExportDirectoryPath: String? {
        get {
            let p = UserDefaults.standard.string(forKey: Self.exportFolderDefaultsKey)
            return (p?.isEmpty == false) ? p : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.exportFolderDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.exportFolderDefaultsKey)
            }
        }
    }

    public func loadAll() -> [PaperDigestRecord] {
        lock.withLock {
            guard FileManager.default.fileExists(atPath: storageURL.path),
                  let data = try? Data(contentsOf: storageURL),
                  !data.isEmpty else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            if let records = try? decoder.decode([PaperDigestRecord].self, from: data) {
                return records.sorted { $0.createdAt > $1.createdAt }
            }
            if let lossy = try? decoder.decode(LossyPaperRecordArray.self, from: data),
               !lossy.elements.isEmpty {
                return lossy.elements.sorted { $0.createdAt > $1.createdAt }
            }

            let backupURL = storageURL.deletingLastPathComponent()
                .appendingPathComponent("paper_digests.backup-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: storageURL, to: backupURL)
            return []
        }
    }

    public func saveAll(_ records: [PaperDigestRecord]) {
        lock.withLock {
            let sorted = records.sorted { $0.createdAt > $1.createdAt }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(sorted) else { return }
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    public func writeMarkdownFile(for record: PaperDigestRecord, directoryURL: URL) throws -> String {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let baseFilename = record.suggestedMarkdownFilename()
        let stem = (baseFilename as NSString).deletingPathExtension
        var candidateURL = directoryURL.appendingPathComponent(baseFilename)

        // If updating the exact same record's previously exported file, overwrite in place; otherwise avoid colliding with another record's file
        if let existingOwnPath = record.exportedMarkdownPath,
           URL(fileURLWithPath: existingOwnPath).deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL {
            candidateURL = URL(fileURLWithPath: existingOwnPath)
        } else {
            var suffix = 2
            while FileManager.default.fileExists(atPath: candidateURL.path) {
                candidateURL = directoryURL.appendingPathComponent("\(stem)-\(suffix).md")
                suffix += 1
            }
        }

        let mdContent = record.toMarkdown(includeFrontmatter: true)
        try mdContent.write(to: candidateURL, atomically: true, encoding: .utf8)
        return candidateURL.path
    }
}
