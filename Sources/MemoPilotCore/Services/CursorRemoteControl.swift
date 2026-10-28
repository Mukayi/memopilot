import Foundation

public struct RemoteControlCommand: Codable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var action: String
    public var text: String?
    public var planJSON: String?
    public var theme: String?
    public var autoCommit: Bool?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        action: String,
        text: String? = nil,
        planJSON: String? = nil,
        theme: String? = nil,
        autoCommit: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.action = action
        self.text = text
        self.planJSON = planJSON
        self.theme = theme
        self.autoCommit = autoCommit
    }
}

public enum CursorRemoteControl {
    public static let notificationName = Notification.Name("com.xiatianze.MemoPilot.RemoteCommand")

    public static let ipcDirectoryURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MemoPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static var commandFilePath: String {
        ipcDirectoryURL.appendingPathComponent("remote-cmd.json").path
    }

    public static var responseFilePath: String {
        ipcDirectoryURL.appendingPathComponent("remote-resp.txt").path
    }

    public static func sendCommand(_ command: RemoteControlCommand) throws -> String {
        try? FileManager.default.removeItem(atPath: responseFilePath)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(command)
        try data.write(to: URL(fileURLWithPath: commandFilePath), options: .atomic)

        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        let timeoutSeconds = command.action == "analyze" ? 60.0 : 3.5
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseFilePath),
               let resp = try? String(contentsOfFile: responseFilePath, encoding: .utf8),
               !resp.isEmpty {
                try? FileManager.default.removeItem(atPath: responseFilePath)
                return resp
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Clean up unconsumed command file so it never becomes a ghost command on next launch
        try? FileManager.default.removeItem(atPath: commandFilePath)
        return "⚠️ MemoPilot 未响应或未启动（已清理挂起指令 \(command.action)）"
    }

    public static func writeResponse(_ message: String) {
        try? message.write(toFile: responseFilePath, atomically: true, encoding: .utf8)
    }
}
