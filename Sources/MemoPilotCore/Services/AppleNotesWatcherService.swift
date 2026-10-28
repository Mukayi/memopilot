import Foundation
import AppKit

public struct WatchedAppleNote: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var plaintext: String
    public var body: String

    public init(id: String, title: String, plaintext: String, body: String) {
        self.id = id
        self.title = title
        self.plaintext = plaintext
        self.body = body
    }
}

public final class AppleNotesWatcherService: @unchecked Sendable {
    public static let shared = AppleNotesWatcherService()
    public static let watchFolderName = "MemoPilot"
    public static let processedMarker = "✅ MemoPilot 已自动拆解"

    private let stateFileURL: URL
    private let lock = NSLock()
    private var isScanning = false

    public init(baseDirectoryURL: URL? = nil) {
        let baseDir: URL
        if let baseDirectoryURL {
            baseDir = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            baseDir = appSupport.appendingPathComponent("MemoPilot", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.stateFileURL = baseDir.appendingPathComponent("processed-apple-notes.json")
    }

    public static func normalizeNoteText(_ raw: String) -> String {
        var lines = raw.components(separatedBy: .newlines)
        lines.removeAll { line in
            line.contains(processedMarker)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isNoteAlreadyProcessed(noteID: String, plaintext: String) -> Bool {
        if plaintext.contains(Self.processedMarker) {
            return true
        }
        let clean = Self.normalizeNoteText(plaintext)
        guard !clean.isEmpty else { return true }
        let map = loadProcessedMap()
        return map[noteID] == clean
    }

    public func recordNoteProcessed(noteID: String, plaintext: String) {
        let clean = Self.normalizeNoteText(plaintext)
        lock.withLock {
            var map = loadProcessedMapUnlocked()
            map[noteID] = clean
            saveProcessedMapUnlocked(map)
        }
    }

    public func fetchUnprocessedNotes(allowLaunchingNotesApp: Bool = false) async throws -> [WatchedAppleNote] {
        if !allowLaunchingNotesApp {
            let isNotesRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
            guard isNotesRunning else { return [] }
        }

        let canProceed: Bool = lock.withLock {
            if isScanning { return false }
            isScanning = true
            return true
        }
        guard canProceed else { return [] }
        defer {
            lock.withLock { isScanning = false }
        }

        return try await Task.detached(priority: .utility) {
            let jxaScript = """
            function run(argv) {
                const shouldCreate = (argv.length > 0 && argv[0] === "true");
                const Notes = Application("Notes");
                const acc = Notes.defaultAccount();
                let folder = acc.folders.byName("MemoPilot");
                try {
                    folder.id();
                } catch (e) {
                    if (!shouldCreate) {
                        return "[]";
                    }
                    folder = Notes.Folder({name: "MemoPilot"});
                    acc.folders.push(folder);
                }
                const notes = folder.notes();
                const result = [];
                for (let i = 0; i < Math.min(notes.length, 20); i++) {
                    const n = notes[i];
                    result.push({
                        id: String(n.id()),
                        title: String(n.name() || ""),
                        plaintext: String(n.plaintext() || ""),
                        body: String(n.body() || "")
                    });
                }
                return JSON.stringify(result);
            }
            """

            let jsonOut = try Self.runJXAScript(
                jxaScript,
                arguments: [allowLaunchingNotesApp ? "true" : "false"],
                timeout: 8.0
            )
            guard let data = jsonOut.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let allNotes = try? JSONDecoder().decode([WatchedAppleNote].self, from: data) else {
                return []
            }

            return allNotes.filter { note in
                let cleaned = Self.normalizeNoteText(note.plaintext)
                guard !cleaned.isEmpty else { return false }
                return !self.isNoteAlreadyProcessed(noteID: note.id, plaintext: note.plaintext)
            }
        }.value
    }

    public func markNoteAsProcessed(note: WatchedAppleNote, summary: String) async {
        recordNoteProcessed(noteID: note.id, plaintext: note.plaintext)

        await Task.detached(priority: .utility) {
            let safeSummary = AppleExecutors.htmlEscape(summary.isEmpty ? "已生成草稿" : summary)
            let stampHTML = "<br><hr><p><small>\(Self.processedMarker)：\(safeSummary)</small></p>"
            let jxaScript = """
            function run(argv) {
                const targetID = argv[0] || "";
                const stamp = argv[1] || "";
                const Notes = Application("Notes");
                const folder = Notes.defaultAccount().folders.byName("MemoPilot");
                const notes = folder.notes();
                for (let i = 0; i < notes.length; i++) {
                    const n = notes[i];
                    if (String(n.id()) === targetID) {
                        const currentBody = String(n.body() || "");
                        if (!currentBody.includes("\(Self.processedMarker)")) {
                            n.body = currentBody + stamp;
                        }
                        break;
                    }
                }
            }
            """
            _ = try? Self.runJXAScript(jxaScript, arguments: [note.id, stampHTML], timeout: 8.0)
        }.value
    }

    // MARK: - Persistence Helpers

    private func loadProcessedMap() -> [String: String] {
        lock.withLock {
            loadProcessedMapUnlocked()
        }
    }

    private func loadProcessedMapUnlocked() -> [String: String] {
        guard FileManager.default.fileExists(atPath: stateFileURL.path),
              let data = try? Data(contentsOf: stateFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveProcessedMapUnlocked(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    private static func runJXAScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw NSError(domain: "MemoPilot.NotesWatcher", code: -1, userInfo: [NSLocalizedDescriptionKey: "访问备忘录超时"])
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "MemoPilot.NotesWatcher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errStr])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
