import Foundation
import ServiceManagement

public enum LaunchAtLoginService {
    private static var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.xiatianze.MemoPilot.plist")
    }

    public static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                return
            } catch {
                writeLaunchAgentPlist()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(atPath: launchAgentPlistURL.path)
        }
    }

    private static func writeLaunchAgentPlist() {
        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let executablePath: String
        if FileManager.default.isExecutableFile(atPath: "/Applications/MemoPilot.app/Contents/MacOS/MemoPilot") {
            executablePath = "/Applications/MemoPilot.app/Contents/MacOS/MemoPilot"
        } else {
            executablePath = Bundle.main.executablePath ?? "/Applications/MemoPilot.app/Contents/MacOS/MemoPilot"
        }
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.xiatianze.MemoPilot</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        try? plistContent.write(to: launchAgentPlistURL, atomically: true, encoding: .utf8)
    }
}
