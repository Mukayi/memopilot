import Foundation
import AppKit

public enum AIProviderMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "自动（优先 Cursor）"
    case cursor = "Cursor 直连"
    case openai = "OpenAI Codex"

    public var id: String { rawValue }
}

public struct CodexEnvironmentStatus: Sendable, Equatable {
    public var codexBinaryPath: String?
    public var cursorBinaryPath: String?
    public var isLoggedIn: Bool
    public var activeProviderLabel: String
    public var statusMessage: String

    public init(
        codexBinaryPath: String? = nil,
        cursorBinaryPath: String? = nil,
        isLoggedIn: Bool,
        activeProviderLabel: String = "Cursor 已连接",
        statusMessage: String
    ) {
        self.codexBinaryPath = codexBinaryPath
        self.cursorBinaryPath = cursorBinaryPath
        self.isLoggedIn = isLoggedIn
        self.activeProviderLabel = activeProviderLabel
        self.statusMessage = statusMessage
    }

    public var isReady: Bool {
        isLoggedIn && (cursorBinaryPath != nil || codexBinaryPath != nil)
    }
}

public enum CodexCLIBridge {
    public static func augmentedPATH() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var extraPaths = [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        // Resolve any NVM node bin directories if present
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                let binPath = "\(nvmDir)/\(v)/bin"
                if FileManager.default.fileExists(atPath: binPath) {
                    extraPaths.insert(binPath, at: 2)
                    break
                }
            }
        }
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (extraPaths + [existing]).joined(separator: ":")
    }

    public static func findCursorAgentBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/bin/cursor-agent",
            "\(home)/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public static func discoverCursorApiKey() -> String? {
        if let envKey = ProcessInfo.processInfo.environment["CURSOR_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        if let psOut = try? runProcess("/bin/ps", arguments: ["-ax", "-o", "command="], timeout: 3.0),
           let range = psOut.range(of: "crsr_[A-Za-z0-9_]+", options: .regularExpression) {
            let key = String(psOut[range])
            UserDefaults.standard.set(key, forKey: "MemoPilot.cachedCursorApiKey")
            return key
        }
        if let cached = UserDefaults.standard.string(forKey: "MemoPilot.cachedCursorApiKey"), !cached.isEmpty {
            return cached
        }
        return nil
    }

    public static func findCodexBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let whichPath = try? runProcess("/usr/bin/which", arguments: ["codex"], timeout: 2.0).trimmingCharacters(in: .whitespacesAndNewlines),
           !whichPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: whichPath) {
            return whichPath
        }
        return nil
    }

    public static func checkStatus(preferredMode: AIProviderMode = .auto) -> CodexEnvironmentStatus {
        let cursorBin = findCursorAgentBinary()
        let cursorKey = discoverCursorApiKey()
        let isCursorReady = (cursorBin != nil && cursorKey != nil)

        let codexBin = findCodexBinary()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hasCodexAuthFile = FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json")
        let isCodexReady = (codexBin != nil && hasCodexAuthFile)

        switch preferredMode {
        case .cursor:
            if isCursorReady {
                return CodexEnvironmentStatus(
                    codexBinaryPath: codexBin,
                    cursorBinaryPath: cursorBin,
                    isLoggedIn: true,
                    activeProviderLabel: "Cursor 已连接",
                    statusMessage: "已通过本机 Cursor Agent 直连就绪"
                )
            }
        case .openai:
            if isCodexReady {
                return CodexEnvironmentStatus(
                    codexBinaryPath: codexBin,
                    cursorBinaryPath: cursorBin,
                    isLoggedIn: true,
                    activeProviderLabel: "OpenAI 已连接",
                    statusMessage: "已通过 OpenAI Codex CLI 连接就绪"
                )
            }
        case .auto:
            if isCursorReady {
                return CodexEnvironmentStatus(
                    codexBinaryPath: codexBin,
                    cursorBinaryPath: cursorBin,
                    isLoggedIn: true,
                    activeProviderLabel: "Cursor 已连接",
                    statusMessage: "已通过本机 Cursor Agent 自动直连（免额外登录）"
                )
            } else if isCodexReady {
                return CodexEnvironmentStatus(
                    codexBinaryPath: codexBin,
                    cursorBinaryPath: cursorBin,
                    isLoggedIn: true,
                    activeProviderLabel: "OpenAI 已连接",
                    statusMessage: "已通过 OpenAI Codex CLI 连接就绪"
                )
            }
        }

        return CodexEnvironmentStatus(
            codexBinaryPath: codexBin,
            cursorBinaryPath: cursorBin,
            isLoggedIn: false,
            activeProviderLabel: "点击连接 AI",
            statusMessage: "请保持 Cursor 开启，或点击登录 OpenAI 账号"
        )
    }

    public static func checkStatusAsync(preferredMode: AIProviderMode = .auto) async -> CodexEnvironmentStatus {
        await Task.detached(priority: .utility) {
            checkStatus(preferredMode: preferredMode)
        }.value
    }

    public static func openTerminalForInstallOrLogin() {
        let scriptCommand: String
        if let bin = findCodexBinary() {
            let shellQuoted = "'" + bin.replacingOccurrences(of: "'", with: "'\\''") + "'"
            scriptCommand = "\(shellQuoted) login"
        } else {
            scriptCommand = "npm install -g @openai/codex && codex login"
        }
        let escapedForAppleScript = scriptCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escapedForAppleScript)"
        end tell
        """
        if let script = NSAppleScript(source: appleScript) {
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
        }
    }

    public static func analyze(userText: String, imagePath: String?, preferredMode: AIProviderMode = .auto) async throws -> ParsedPlan {
        try await Task.detached(priority: .userInitiated) {
            // 1. Run local Apple Vision OCR on background thread if image is attached
            var combinedText = userText
            if let imagePath, !imagePath.isEmpty {
                let ocrText = VisionOCRService.recognizeText(at: imagePath)
                if !ocrText.isEmpty {
                    combinedText = userText.isEmpty
                        ? "【截图 OCR 识别文本】：\n\(ocrText)"
                        : "\(userText)\n\n【附图 OCR 识别文本】：\n\(ocrText)"
                }
            }

            // 2. Try Cursor Agent Direct Connection first if preferred or in auto mode
            // Note: cursor-agent takes text prompt; if user provided only an image and OCR found 0 text, skip text-only cursor-agent if Codex multimodal is available
            let hasUsableTextForCursor = !combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if preferredMode != .openai,
               hasUsableTextForCursor,
               let cursorBin = findCursorAgentBinary(),
               let cursorKey = discoverCursorApiKey() {
                let prompt = PromptBuilder.buildPrompt(userText: combinedText, hasImage: imagePath != nil)
                let schemaInstruction = "\n\n请只输出一个合法的 JSON 对象（不要用 markdown 代码块包裹，不要任何多余解释），必须严格包含 summary, events, reminders, notes 四个顶级字段，结构遵循：\n\(PromptBuilder.outputJSONSchema)"
                let fullPrompt = prompt + schemaInstruction

                do {
                    let output = try runProcess(
                        cursorBin,
                        arguments: [
                            "--api-key", cursorKey,
                            "--trust",
                            "-p",
                            "--mode", "ask",
                            fullPrompt
                        ],
                        timeout: 90.0
                    )
                    return try ParsedPlan.decode(from: output)
                } catch {
                    // Clear potentially stale cached key
                    UserDefaults.standard.removeObject(forKey: "MemoPilot.cachedCursorApiKey")
                    if preferredMode == .cursor {
                        throw error
                    }
                    // In .auto mode, fall through to OpenAI Codex CLI if available
                }
            }

            // 3. Fallback to OpenAI Codex CLI
            guard let codexPath = findCodexBinary() else {
                if !hasUsableTextForCursor && imagePath != nil {
                    throw NSError(
                        domain: "MemoPilot.AI",
                        code: 422,
                        userInfo: [NSLocalizedDescriptionKey: "未能从截图中识别出清晰文字，请重新框选包含文字的区域或直接输入文字。"]
                    )
                }
                throw NSError(
                    domain: "MemoPilot.AI",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "未检测到可用的 Cursor 连接或 OpenAI Codex 登录状态。"]
                )
            }

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MemoPilot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let schemaURL = tempDir.appendingPathComponent("schema.json")
            let outputURL = tempDir.appendingPathComponent("output.json")
            try PromptBuilder.outputJSONSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

            let prompt = PromptBuilder.buildPrompt(userText: combinedText, hasImage: imagePath != nil)

            var args: [String] = [
                "exec",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--output-schema", schemaURL.path,
                "-o", outputURL.path
            ]
            if let imagePath, !imagePath.isEmpty {
                args.append(contentsOf: ["-i", imagePath])
            }
            args.append(prompt)

            _ = try runProcess(codexPath, arguments: args, timeout: 90.0)
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw NSError(
                    domain: "MemoPilot.Codex",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "AI 未返回结构化结果，请保持 Cursor 开启或点击右上角连接 OpenAI。"]
                )
            }
            let rawJSON = try String(contentsOf: outputURL, encoding: .utf8)
            return try ParsedPlan.decode(from: rawJSON)
        }.value
    }

    @discardableResult
    private static func runProcess(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 90.0
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH()
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Concurrent pipe draining prevents 64KB OS pipe buffer deadlocks
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            process.terminate()
            throw NSError(
                domain: "MemoPilot.Process",
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "AI 响应超时（>\(Int(timeout))秒），请重试。"]
            )
        }

        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw NSError(
                domain: "MemoPilot.Process",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "命令执行失败 (\(process.terminationStatus)): \(stderr.isEmpty ? stdout : stderr)"]
            )
        }
        return stdout
    }
}
