import Foundation
import AppKit
import CFNetwork

public enum AIProviderMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "自动（优先 Cursor）"
    case cursor = "Cursor 直连"
    case openai = "OpenAI Codex"

    public var id: String { rawValue }
}

public enum AISpeedProfile: String, CaseIterable, Identifiable, Sendable {
    case flash = "极速无思考（推荐）"
    case balanced = "均衡低思考"
    case deep = "深度高思考"

    public var id: String { rawValue }

    public var cursorModelSlug: String {
        switch self {
        case .flash: return "gpt-5.4-nano-none"
        case .balanced: return "gpt-5.6-sol-none-fast"
        case .deep: return "gpt-5.6-sol-high-fast"
        }
    }

    public var codexReasoningEffort: String {
        switch self {
        case .flash: return "minimal"
        case .balanced: return "low"
        case .deep: return "medium"
        }
    }
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
            "\(home)/.local/node/bin",
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

    /// Reads macOS System Proxy settings (Clash / Surge / V2Ray / System Settings)
    /// so GUI-launched subprocesses don't hang bypassing the user's proxy.
    public static func systemProxyEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        guard let unmanaged = CFNetworkCopySystemProxySettings(),
              let dict = unmanaged.takeRetainedValue() as? [String: Any] else {
            return env
        }
        if let httpEnable = dict[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnable == 1,
           let host = dict[kCFNetworkProxiesHTTPProxy as String] as? String, !host.isEmpty,
           let port = dict[kCFNetworkProxiesHTTPPort as String] as? Int, port > 0 {
            let url = "http://\(host):\(port)"
            env["HTTP_PROXY"] = url
            env["HTTPS_PROXY"] = url
            env["http_proxy"] = url
            env["https_proxy"] = url
        }
        if let socksEnable = dict[kCFNetworkProxiesSOCKSEnable as String] as? Int, socksEnable == 1,
           let host = dict[kCFNetworkProxiesSOCKSProxy as String] as? String, !host.isEmpty,
           let port = dict[kCFNetworkProxiesSOCKSPort as String] as? Int, port > 0 {
            let url = "socks5://\(host):\(port)"
            env["ALL_PROXY"] = url
            env["all_proxy"] = url
        }
        return env
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
            "\(home)/.local/node/bin/codex",
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

    public static func isCodexAuthenticated(codexBinary: String?) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json") {
            return true
        }
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty {
            return true
        }
        guard let bin = codexBinary else { return false }
        if let statusOut = try? runProcess(bin, arguments: ["login", "status"], timeout: 2.5) {
            let lower = statusOut.lowercased()
            if !lower.contains("not logged in") && !lower.contains("no codex credentials") && !lower.isEmpty {
                return true
            }
        }
        return false
    }

    public static func checkStatus(preferredMode: AIProviderMode = .auto) -> CodexEnvironmentStatus {
        let cursorBin = findCursorAgentBinary()
        let cursorKey = discoverCursorApiKey()
        let isCursorReady = (cursorBin != nil && cursorKey != nil)

        let codexBin = findCodexBinary()
        let isCodexReady = isCodexAuthenticated(codexBinary: codexBin)

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
            activeProviderLabel: "点击登录 AI",
            statusMessage: "请保持 Cursor 开启，或点击「终端登录 OpenAI Codex…」完成网页授权"
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

    public static func analyze(
        userText: String,
        imagePath: String?,
        preferredMode: AIProviderMode = .auto,
        speedProfile: AISpeedProfile = .flash
    ) async throws -> ParsedPlan {
        try await Task.detached(priority: .userInitiated) {
            // Create an isolated empty working directory so neither cursor-agent nor codex ever scans `/` (Finder launch cwd)!
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("MemoPilot-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

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
            let hasUsableTextForCursor = !combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if preferredMode != .openai,
               hasUsableTextForCursor,
               let cursorBin = findCursorAgentBinary(),
               let cursorKey = discoverCursorApiKey() {
                let prompt = PromptBuilder.buildPrompt(userText: combinedText, hasImage: imagePath != nil)
                let schemaInstruction = "\n\n请只输出一个合法的 JSON 对象（不要调用任何工具，不要用 markdown 代码块包裹，不要任何多余解释），必须严格包含 summary, events, reminders, notes 四个顶级字段，结构遵循：\n\(PromptBuilder.outputJSONSchema)"
                let fullPrompt = prompt + schemaInstruction

                do {
                    let output = try runProcess(
                        cursorBin,
                        arguments: [
                            "--api-key", cursorKey,
                            "--trust",
                            "--workspace", tempDir.path,
                            "--model", speedProfile.cursorModelSlug,
                            "-p",
                            "--mode", "ask",
                            fullPrompt
                        ],
                        workingDirectoryURL: tempDir,
                        timeout: 45.0
                    )
                    return try ParsedPlan.decode(from: output)
                } catch {
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
                    userInfo: [NSLocalizedDescriptionKey: "未检测到可用的 Cursor 连接或 OpenAI Codex CLI。请点击右上角连接 AI。"]
                )
            }

            // Verify Codex is actually logged in before running `codex exec` (prevents 90s unauthenticated retry loop)
            guard isCodexAuthenticated(codexBinary: codexPath) else {
                throw NSError(
                    domain: "MemoPilot.CodexAuth",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "尚未登录 OpenAI Codex 账号。请点击窗口右上角「点击登录 AI → 终端登录 OpenAI Codex…」完成授权后再试。"]
                )
            }

            let schemaURL = tempDir.appendingPathComponent("schema.json")
            let outputURL = tempDir.appendingPathComponent("output.json")
            try PromptBuilder.outputJSONSchema.write(to: schemaURL, atomically: true, encoding: .utf8)

            let prompt = PromptBuilder.buildPrompt(userText: combinedText, hasImage: imagePath != nil)
                + "\n\n注意：请直接生成最终 JSON，绝不要调用任何 shell 命令或外部工具。"

            let args = Self.buildCodexExecArguments(
                tempDirPath: tempDir.path,
                schemaPath: schemaURL.path,
                outputPath: outputURL.path,
                imagePath: imagePath,
                prompt: prompt,
                speedProfile: speedProfile
            )

            let processOut = try runProcess(
                codexPath,
                arguments: args,
                workingDirectoryURL: tempDir,
                timeout: 75.0
            )
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                let detail = processOut.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "MemoPilot.Codex",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "OpenAI 未返回结构化结果（请检查代理网络或右上角重新登录 OpenAI）。\(detail.isEmpty ? "" : "\n详情：\(String(detail.suffix(180)))")"]
                )
            }
            let rawJSON = try String(contentsOf: outputURL, encoding: .utf8)
            return try ParsedPlan.decode(from: rawJSON)
        }.value
    }

    public static func buildCodexExecArguments(
        tempDirPath: String,
        schemaPath: String,
        outputPath: String,
        imagePath: String?,
        prompt: String,
        speedProfile: AISpeedProfile = .flash
    ) -> [String] {
        var args: [String] = [
            "exec",
            "--ignore-user-config",
            "--ephemeral",
            "-C", tempDirPath,
            "-c", "model_reasoning_effort=\"\(speedProfile.codexReasoningEffort)\"",
            "--enable", "respect_system_proxy",
            "--disable", "shell_tool",
            "--disable", "shell_snapshot",
            "--disable", "plugins",
            "--disable", "apps",
            "--disable", "browser_use",
            "--disable", "computer_use",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--output-schema", schemaPath,
            "-o", outputPath
        ]
        if let imagePath, !imagePath.isEmpty {
            args.append(contentsOf: ["-i", imagePath])
        }
        // `--` terminates variadic `-i <FILE>...` option parsing so `prompt` is never swallowed as a second image file!
        args.append("--")
        args.append(prompt)
        return args
    }

    @discardableResult
    private static func runProcess(
        _ executable: String,
        arguments: [String],
        workingDirectoryURL: URL? = nil,
        timeout: TimeInterval = 75.0
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let workingDirectoryURL {
            process.currentDirectoryURL = workingDirectoryURL
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH()
        // Inject macOS System Proxy if not already set in environment
        for (k, v) in systemProxyEnvironment() where env[k] == nil {
            env[k] = v
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

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
                userInfo: [NSLocalizedDescriptionKey: "AI 响应超时（>\(Int(timeout))秒），请检查网络连接/系统代理或重试。"]
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
        return stdout.isEmpty ? stderr : stdout
    }
}
